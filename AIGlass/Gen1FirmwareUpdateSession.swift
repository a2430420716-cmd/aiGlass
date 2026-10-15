import Foundation

/// Main-firmware OTA only. The glasses join a router and download HTTP themselves;
/// this session never starts an AP, uploads a file, or invokes the Bluetooth OTA SDK.
@MainActor
final class Gen1FirmwareUpdateSession {
    enum Phase: Equatable {
        case checkingBattery, provisioningWifi(Int), diagnosingWifi
        case upgrading(Int), restarting, verifyingVersion, completed
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable, targetChanged, batteryUnknown, batteryLow(Int), sendFailed(UInt8)
        case wifiProvisionFailed, otaRejected(UInt8), startTimedOut, progressTimedOut
        case wifiResponseTimedOut, wifiUnexpectedResult(UInt8), wifiMalformedResponse, wifiConnectionLost
        case reconnectTimedOut, versionNotConfirmed(String?)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "眼镜当前不可升级，请先结束拍摄、录音或导入，并确认已绑定当前账号"
            case .targetChanged: return "账号、绑定或连接的眼镜已改变，本次升级已停止"
            case .batteryUnknown: return "未能读取眼镜电量，请重新连接后再升级"
            case .batteryLow(let level): return "眼镜电量不足（当前\(level)%），一代主固件升级需要电量至少 80%"
            case .sendFailed(let command): return String(format: "升级指令 0x%02X 未发送，请重新连接眼镜后重试", command)
            case .wifiProvisionFailed: return "眼镜回复 Wi-Fi 配置失败。请确认网络为 2.4GHz，并检查名称和密码；此回复未说明具体原因"
            case .wifiResponseTimedOut: return "未收到眼镜的 Wi-Fi 配置结果，已停止升级。请导出 Wi-Fi 和蓝牙日志排查；这不代表密码错误"
            case .wifiUnexpectedResult(let code): return String(format: "眼镜返回未识别的 Wi-Fi 配置结果（0x%02X），升级未开始，请导出日志排查", code)
            case .wifiMalformedResponse: return "眼镜的 Wi-Fi 配置回包格式异常，升级未开始，请导出 Wi-Fi 和蓝牙日志排查"
            case .wifiConnectionLost: return "配置 Wi-Fi 时眼镜蓝牙连接中断，未能确认配网结果。请重新连接后重试"
            case .otaRejected(let code): return code == 0xE3 ? "眼镜忙碌，无法开始固件升级" : "眼镜无法开始固件升级，请检查眼镜的 Wi-Fi 网络"
            case .startTimedOut: return "未收到固件升级进度，请检查眼镜连接的 Wi-Fi 是否可以访问互联网"
            case .progressTimedOut: return "固件升级进度超时，请保持眼镜供电，重新连接后检查版本"
            case .reconnectTimedOut: return "固件已写入，但眼镜蓝牙未恢复，无法下发重启；请重连后检查版本"
            case .versionNotConfirmed(let version): return "尚未确认重启后的固件版本（\(version ?? "未读取到版本")），请重新连接眼镜检查"
            }
        }
    }

    nonisolated struct Timing: Sendable {
        var battery: TimeInterval = 3
        var provisioning: TimeInterval = 30
        var diagnostics: TimeInterval = 3
        var firstProgress: TimeInterval = 30
        var progress: TimeInterval = 180
        var reconnect: TimeInterval = 30
        var reboot: TimeInterval = 3
        var version: TimeInterval = 90
        var poll: TimeInterval = 0.2
    }

    private let send: (UInt8, Data) -> Bool
    private let validate: () throws -> Void
    private let isConnected: () -> Bool
    private let reconnect: () -> Void
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private let changed: (Phase) -> Void
    private let logOutput: (String) -> Void
    private var startedAt: TimeInterval?
    private var phaseStartedAt: TimeInterval?
    private var malformedWifiResponse = false
    private var lastWaitLogAt: TimeInterval = 0
    private var lastConnectionState: Bool?
    private let timing: Timing
    private(set) var phase: Phase?
    private var battery: Int?
    private var wifiResult: UInt8?
    private var wifiDiagnostic: Data?
    private var progress: Int?
    private var lastProgressAt: TimeInterval = 0
    private var rejection: UInt8?
    private var freshVersion: String?

    init(timing: Timing = Timing(), send: @escaping (UInt8, Data) -> Bool,
         validate: @escaping () throws -> Void, isConnected: @escaping () -> Bool,
         reconnect: @escaping () -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = {
             try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
         }, changed: @escaping (Phase) -> Void, log: @escaping (String) -> Void) {
        self.timing = timing
        self.send = send
        self.validate = validate
        self.isConnected = isConnected
        self.reconnect = reconnect
        self.now = now
        self.sleep = sleep
        self.changed = changed
        self.logOutput = log
    }

    /// Caller has already checked generation, account and peripheral identity.
    /// Ignore late replies from previous phases; no reply can skip provisioning.
    func receive(command: UInt8, payload: Data) {
        let relevant: Set<UInt8> = [0x05, 0x06, 0x09, 0x17, 0x18, 0x3A, 0x15, 0x72, 0x73]
        guard (try? validate()) != nil, isConnected() else {
            if relevant.contains(command) { log("rx ignored command=\(hex(command)) payloadBytes=\(payload.count) reason=identity_or_connection_invalid") }
            return
        }
        if relevant.contains(command) {
            // Never dump provisioning/diagnostic payloads: they can contain credentials.
            let status = [UInt8(0x06), 0x09, 0x72, 0x73].contains(command) && payload.count == 1
                ? hex(payload[payload.startIndex]) : "notLogged"
            log("rx command=\(hex(command)) payloadBytes=\(payload.count) status=\(status) payload=<redacted>")
        }
        switch phase {
        case .checkingBattery where command == 0x05:
            if let value = payload.first, value <= 100 { battery = Int(value) }
        case .provisioningWifi where command == 0x06:
            guard payload.count == 1 else {
                malformedWifiResponse = true
                log("wifi reply ignored reason=expected_exactly_one_status_byte")
                return
            }
            if wifiResult == nil { wifiResult = payload.first }
        case .diagnosingWifi where command == 0x17:
            wifiDiagnostic = payload
        case .upgrading:
            if command == 0x09, let code = payload.first, code == 0 || code == 0xE3 {
                rejection = code
            } else if let value = Gen1FirmwareUpdateProtocol.progress(command: command, payload: payload) {
                progress = max(progress ?? 0, value)
                lastProgressAt = now()
                log("progress command=0x\(String(format: "%02X", command)) percent=\(value)")
            }
        case .verifyingVersion where command == 0x15:
            freshVersion = String(data: payload, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        default:
            if relevant.contains(command) { log("rx not_consumed command=\(hex(command)) reason=not_expected_in_current_phase") }
        }
    }

    func run(wifi: Gen1FirmwareWifiCredentials, urlPayload: Data,
             targetVersion: String, baselineBattery: Int?) async throws {
        precondition(phase == nil, "An OTA session cannot be reused")
        startedAt = now()
        lastWaitLogAt = now()
        defer { log("session ended completed=\(phase == .completed); OTA_start_requires_explicit_0x06_success") }
        try check()
        let credentials = try Gen1FirmwareUpdateProtocol.wifiPayload(ssid: wifi.ssid, password: wifi.password)
        log("input targetVersion=\(targetVersion) wifiPayloadBytes=\(credentials.count) urlPayloadBytes=\(urlPayload.count) ssidTrimmed=\(wifi.ssid != wifi.ssid.trimmingCharacters(in: .whitespacesAndNewlines)) passwordHasBoundaryWhitespace=\(wifi.password != wifi.password.trimmingCharacters(in: .whitespacesAndNewlines)); password_preserved=true credentials_not_logged=true")
        setPhase(.checkingBattery)
        let queried = transmit(0x05, Data())
        let batteryDeadline = now() + timing.battery
        while queried, battery == nil, now() < batteryDeadline { try await pause() }
        try check()
        guard let level = Gen1FirmwareUpdateProtocol.batteryLevel(reported: battery, baseline: baselineBattery) else {
            throw Failure.batteryUnknown
        }
        log("battery reported=\(battery.map(String.init) ?? "nil") baseline=\(baselineBattery.map(String.init) ?? "nil") effective=\(level)")
        guard level >= Gen1FirmwareUpdateProtocol.minimumBatteryPercent else { throw Failure.batteryLow(level) }

        var provisioned = false
        for attempt in 1...2 {
            try check()
            wifiResult = nil
            malformedWifiResponse = false
            setPhase(.provisioningWifi(attempt))
            log("wifi provision attempt=\(attempt)/2 timeoutSeconds=\(timing.provisioning) ssidBytes=\(wifi.ssid.utf8.count) passwordBytes=\(wifi.password.utf8.count)")
            guard isConnected() else { throw Failure.wifiConnectionLost }
            guard transmit(0x06, credentials) else { throw Failure.sendFailed(0x06) }
            let deadline = now() + timing.provisioning
            while wifiResult == nil, now() < deadline {
                guard isConnected() else { throw Failure.wifiConnectionLost }
                try await pause()
            }
            try check()
            log("wifi response=\(wifiResult.map { String(format: "0x%02X", $0) } ?? "timeout")")
            if wifiResult == 1 { provisioned = true; break }
        }
        guard provisioned else {
            let failure: Failure
            if let wifiResult {
                failure = wifiResult == 0 ? .wifiProvisionFailed : .wifiUnexpectedResult(wifiResult)
            } else {
                failure = malformedWifiResponse ? .wifiMalformedResponse : .wifiResponseTimedOut
            }
            log("wifi failed classification=\(failure); OTA_command_0x09_not_sent=true")
            try await diagnoseWifi()
            throw failure
        }

        try check()
        setPhase(.upgrading(0))
        lastProgressAt = now()
        // Success has no 0x09 ACK. Only a progress notification confirms startup.
        guard transmit(0x09, urlPayload) else { throw Failure.sendFailed(0x09) }
        var lastReconnectAt = -Double.infinity
        while true {
            try check()
            if let rejection { throw Failure.otaRejected(rejection) }
            if let progress { setPhase(.upgrading(progress)) }
            if progress == 100 { break }
            let timeout = progress == nil ? timing.firstProgress : timing.progress
            guard now() - lastProgressAt < timeout else {
                throw progress == nil ? Failure.startTimedOut : Failure.progressTimedOut
            }
            if !isConnected(), now() - lastReconnectAt >= 2 {
                lastReconnectAt = now()
                reconnect()
            }
            try await pause()
        }

        setPhase(.restarting)
        let reconnectDeadline = now() + timing.reconnect
        while !isConnected() {
            guard now() < reconnectDeadline else { throw Failure.reconnectTimedOut }
            if now() - lastReconnectAt >= 2 { lastReconnectAt = now(); reconnect() }
            try await pause()
        }
        try check()
        guard transmit(0x12, Data()) else { throw Failure.sendFailed(0x12) }
        // Keep validating ownership throughout the reboot delay.
        let rebootDeadline = now() + timing.reboot
        while now() < rebootDeadline { try await pause() }
        setPhase(.verifyingVersion)
        let versionDeadline = now() + timing.version
        var lastQueryAt = -Double.infinity
        while now() < versionDeadline {
            try check()
            if isConnected(), now() - lastQueryAt >= 3 {
                lastQueryAt = now()
                _ = transmit(0x15, Data())
            } else if !isConnected(), now() - lastReconnectAt >= 2 {
                lastReconnectAt = now()
                reconnect()
            }
            if let freshVersion, Gen1FirmwareUpdateProtocol.versionsMatch(freshVersion, target: targetVersion) {
                setPhase(.completed)
                return
            }
            try await pause()
        }
        throw Failure.versionNotConfirmed(freshVersion)
    }

    private func diagnoseWifi() async throws {
        try check()
        setPhase(.diagnosingWifi)
        guard transmit(0x17, Data()) else { log("wifi diagnostic command not sent"); return }
        let deadline = now() + timing.diagnostics
        while wifiDiagnostic == nil, now() < deadline { try await pause() }
        try check()
        log("wifi diagnostic=\(wifiDiagnostic == nil ? "timeout" : "received") payloadBytes=\(wifiDiagnostic?.count ?? 0) utf8Valid=\(wifiDiagnostic.flatMap { String(data: $0, encoding: .utf8) } != nil) payload=<redacted>; diagnostic_is_not_connectivity_success")
    }

    private func setPhase(_ value: Phase) {
        guard phase != value else { return }
        log("phase transition next=\(value)")
        phase = value
        phaseStartedAt = now()
        changed(value)
    }

    private func check() throws {
        try Task.checkCancellation()
        try validate()
    }

    private func pause() async throws {
        try check()
        try await sleep(timing.poll)
        try check()
        let connected = isConnected()
        if lastConnectionState != connected || now() - lastWaitLogAt >= 5 {
            lastConnectionState = connected
            lastWaitLogAt = now()
            log("waiting progress=\(progress.map(String.init) ?? "none") lastProgressAge=\(String(format: "%.1f", now() - lastProgressAt))s")
        }
    }

    private func transmit(_ command: UInt8, _ payload: Data) -> Bool {
        log("tx begin command=\(hex(command)) payloadBytes=\(payload.count) payload=<redacted>")
        let queued = send(command, payload)
        log("tx result command=\(hex(command)) queued=\(queued); queued_is_not_device_ack")
        return queued
    }

    private func hex(_ value: UInt8) -> String { String(format: "0x%02X", value) }

    private func log(_ message: String) {
        let elapsed = startedAt.map { now() - $0 } ?? 0
        let phaseElapsed = phaseStartedAt.map { now() - $0 } ?? 0
        logOutput("elapsed=\(String(format: "%.3f", elapsed))s phase=\(phase.map { String(describing: $0) } ?? "notStarted") phaseElapsed=\(String(format: "%.3f", phaseElapsed))s bleConnected=\(isConnected()) \(message)")
    }
}
