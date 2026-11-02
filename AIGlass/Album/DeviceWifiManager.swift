import Foundation
import NetworkExtension

enum DeviceWifiError: LocalizedError {
    case userDenied
    case joinFailed(String)
    case unreachable
    case hotspotStopped

    var errorDescription: String? {
        switch self {
        case .userDenied:
            return L10n.t("已取消加入眼镜 Wi-Fi", "Cancelled joining glasses Wi-Fi")
        case .joinFailed(let detail):
            return L10n.t("连接眼镜 Wi-Fi 失败：\(detail)", "Failed to join glasses Wi-Fi: \(detail)")
        case .unreachable:
            return L10n.t("未能连接眼镜热点，请确认眼镜热点已开启", "Could not connect to glasses Wi-Fi. Confirm the glasses hotspot is enabled")
        case .hotspotStopped:
            return L10n.t("眼镜已报告主控关机，请重新开启热点后连接", "The glasses reported controller shutdown. Restart the hotspot before connecting")
        }
    }
}

enum DeviceWifiManager {
    private static let logTag = "[DeviceWifi]"
    private static let managedHotspotsKey = "DeviceWifiManager.managedTransferHotspots"
    private static var configurationAttempts: [String: UUID] = [:]
    private static var configurationRemovalTimes: [String: TimeInterval] = [:]

    /// Only remove networks installed by a previous transfer, never user-managed Wi-Fi.
    static func removeStaleTransferConfigurations() {
        let ssids = UserDefaults.standard.stringArray(forKey: managedHotspotsKey) ?? []
        for ssid in ssids {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            configurationRemovalTimes[ssid] = ProcessInfo.processInfo.systemUptime
        }
        UserDefaults.standard.removeObject(forKey: managedHotspotsKey)
    }

    private static func rememberTransferConfiguration(_ ssid: String) {
        var ssids = Set(UserDefaults.standard.stringArray(forKey: managedHotspotsKey) ?? [])
        ssids.insert(ssid)
        UserDefaults.standard.set(Array(ssids), forKey: managedHotspotsKey)
    }

    private static func removeTransferConfiguration(_ ssid: String) {
        configurationAttempts.removeValue(forKey: ssid)
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        configurationRemovalTimes[ssid] = ProcessInfo.processInfo.systemUptime
        let ssids = (UserDefaults.standard.stringArray(forKey: managedHotspotsKey) ?? []).filter { $0 != ssid }
        UserDefaults.standard.set(ssids, forKey: managedHotspotsKey)
    }

    /// 系统接受热点配置后，等待目标热点身份和有效 IPv4 的最长时间。
    private static let readyTimeout: TimeInterval = 30
    private static let readinessPollInterval: TimeInterval = 1

    /// 加入眼镜热点：apply 前清掉旧配置，apply 后每秒检查目标热点身份及有效 IPv4。
    /// 对齐安卓的分阶段流程；返回只表示热点网络就绪，HTTP 服务由后续业务请求确认。
    /// 失败直接抛出，由相册/录音/OTA 终止本次任务；不在公共层静默重试。
    /// - Parameter probeBaseURL: 后续眼镜 HTTP 服务地址，仅供关联诊断日志。
    static func connect(
        ssid: String,
        password: String,
        probeBaseURL: String = "http://192.168.0.1/",
        diagnosticContext: String = "unspecified",
        diagnosticID: String = UUID().uuidString,
        deviceEvidence: (@MainActor () -> String)? = nil,
        keepConnectionInBackground: Bool = false
    ) async throws {
        let probeEndpoint = ProbeEndpoint(baseURL: probeBaseURL)
        let diagnostics = WifiDiagnosticSession(
            targetSSID: ssid, context: diagnosticContext, id: diagnosticID, deviceEvidence: deviceEvidence,
            joinOnce: !keepConnectionInBackground
        )
        defer { diagnostics.stop() }
        diagnostics.recordSnapshot(phase: "before-apply", force: true)
        print("\(logTag) join ssid=\(ssid)")
        diagnostics.log(
            "开始加入眼镜热点",
            detail: "targetSSID=\(ssid)\npassword=\(password.debugDescription)\npasswordUTF8Bytes=\(password.utf8.count)\npasswordEmpty=\(password.isEmpty)\nserviceEndpoint=\(probeEndpoint.host):\(probeEndpoint.port)\nreadyTimeout=\(Int(readyTimeout))s pollInterval=\(readinessPollInterval)s\nreadinessCondition=targetIdentityAndUsableWiFiIPv4 TCPVerified=false HTTPResponseVerified=false",
            direction: .sent
        )

        // 残留配置会让 apply 直接返回 alreadyAssociated，却未真正关联到眼镜。
        removeTransferConfiguration(ssid)
        diagnostics.log("移除旧热点配置", detail: "ssid=\(ssid)")
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            if keepConnectionInBackground { rememberTransferConfiguration(ssid) }
            try await applyConfiguration(ssid: ssid, password: password, diagnostics: diagnostics, joinOnce: !keepConnectionInBackground)
        } catch {
            diagnostics.recordSnapshot(phase: "apply-failed-before-cleanup", force: true)
            diagnostics.log("热点申请失败，移除配置", detail: "callerTaskCancelled=\(Task.isCancelled)")
            removeTransferConfiguration(ssid)
            print("\(logTag) apply failed, abort task: \(error.localizedDescription)")
            let nsError = error as NSError
            diagnostics.log(
                "系统加入热点失败，本次任务终止",
                detail: "ssid=\(ssid)\ndomain=\(nsError.domain)\ncode=\(nsError.code)\nerror=\(error.localizedDescription)",
                direction: .received
            )
            throw error
        }

        do {
            guard try await waitUntilReady(ssid: ssid, timeout: readyTimeout, diagnostics: diagnostics) else {
                throw DeviceWifiError.unreachable
            }
            try Task.checkCancellation()
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            diagnostics.recordSnapshot(phase: cancelled ? "cancelled-before-cleanup" : "timeout-before-cleanup", force: true)
            diagnostics.log("热点等待结束，移除配置", detail: "reason=\(cancelled ? "caller-cancelled" : "readiness-timeout"); snapshot_recorded_before_cleanup")
            removeTransferConfiguration(ssid)
            diagnostics.log(
                cancelled ? "热点连接已取消" : "热点关联或 IP 获取超时，本次任务终止",
                detail: "targetSSID=\(ssid)\ntimeout=\(Int(readyTimeout))s\nserviceEndpoint=\(probeEndpoint.host):\(probeEndpoint.port)\nTCPVerified=false HTTPResponseVerified=false",
                direction: .received
            )
            throw error
        }

        print("\(logTag) hotspot identity and IPv4 ready ssid=\(ssid)")
        diagnostics.log(
            "眼镜热点身份与 IPv4 校验通过",
            detail: "ssid=\(ssid)\nserviceEndpoint=\(probeEndpoint.host):\(probeEndpoint.port)\nTCPVerified=false HTTPResponseVerified=false; next_stage_verifies_HTTP_service",
            direction: .received
        )
    }

    /// Gen1 firmware serves media at a fixed endpoint. Apply the device's SSID,
    /// then require the glasses LAN IPv4 before the Wi-Fi-only TCP connection.
    static func connectGen1(
        ssid: String,
        password: String,
        diagnosticID: String,
        deviceEvidence: (@MainActor () -> String)? = nil,
        validateSession: (@MainActor () throws -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        try validateSession?()
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            throw DeviceWifiError.joinFailed(L10n.t("眼镜热点名称无效，请重新开启热点后重试", "Invalid glasses hotspot name. Restart the hotspot and try again"))
        }
        let diagnostics = WifiDiagnosticSession(
            targetSSID: ssid, context: "gen1-media-import", id: diagnosticID, deviceEvidence: deviceEvidence,
            joinOnce: false
        )
        defer { diagnostics.stop() }
        if gen1HasClientIPv4 {
            diagnostics.log("已在眼镜网段，跳过系统加入申请", detail: "applySkipped=true target_LAN_IPv4_is_required_before_TCP=true endpoint=192.168.4.1:8556")
            return "192.168.4.1"
        }
        diagnostics.log(
            "开始加入一代眼镜热点",
            detail: "targetSSID=\(ssid.debugDescription) passwordUTF8Bytes=\(password.utf8.count)"
                + "\nserviceEndpoint=192.168.4.1:8556 endpointSource=fixedFirmwareAddress"
                + "\nidentityPolicy=applyThenRequireGlassesLANThenTCP ssidReadRequired=false gatewayReadRequired=false",
            direction: .sent
        )
        do {
            // Removing and immediately reapplying the same SSID can race iOS's
            // asynchronous disassociation. Never remove a working config to join.
            if let removedAt = configurationRemovalTimes[ssid] {
                let remaining = 3 - (ProcessInfo.processInfo.systemUptime - removedAt)
                if remaining > 0 {
                    diagnostics.log("等待上次热点配置移除完成", detail: "retryKind=joinSystemNetwork delaySeconds=\(remaining)")
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }
            try Task.checkCancellation()
            rememberTransferConfiguration(ssid)
            do {
                try await applyConfiguration(ssid: ssid, password: password, diagnostics: diagnostics,
                                             includePasswordInDiagnostics: false, joinOnce: false, timeout: 45,
                                             retainConfigurationUntilSessionCleanup: true,
                                             validateSession: validateSession)
            } catch {
                try Task.checkCancellation()
                try validateSession?()
                // Some iOS joins report failure while DHCP is still completing.
                // Verify the LAN before reporting an application failure.
                diagnostics.log("系统加入回调报错，仍检查眼镜网段", detail: "error=\(error.localizedDescription) applicationFailureNotPublished=true")
            }
            guard try await waitForGen1ClientIPv4(diagnostics: diagnostics, validateSession: validateSession) else {
                throw DeviceWifiError.unreachable
            }
            try Task.checkCancellation()
            try validateSession?()
            diagnostics.log("一代热点配置已应用，连接固定文件服务", detail: "ssid=\(ssid.debugDescription)"
                + "\nserviceEndpoint=192.168.4.1:8556 TCPVerified=false glassesLANIPv4Confirmed=true"
                + "\nnextStage=WiFiOnlyTCPMediaTransport ssidReadRequired=false gatewayReadRequired=false", direction: .received)
            return "192.168.4.1"
        } catch {
            diagnostics.log("一代热点尚未就绪，交由导入会话处理", detail: "ssid=\(ssid.debugDescription)"
                + "\ncancelled=\(error is CancellationError || Task.isCancelled) error=\(error.localizedDescription)"
                + "\nserviceEndpoint=192.168.4.1:8556 TCPVerified=false", direction: .received)
            throw error
        }
    }

    static var gen1HasClientIPv4: Bool {
        WifiConnectionDiagnostics.isGen1ClientIPv4(WifiDiagnosticSession.captureInterfaces().selectedIPv4)
    }

    /// Allow iOS to finish switching networks and acquiring DHCP even when its
    /// apply callback arrives early. Never repeat apply or probe TCP on another LAN.
    private static func waitForGen1ClientIPv4(
        diagnostics: WifiDiagnosticSession,
        validateSession: (@MainActor () throws -> Void)? = nil
    ) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        diagnostics.log("等待手机切换至眼镜网段", detail: "connectionGrace=30s pollInterval=250ms repeatApply=false TCPAttempted=false")
        repeat {
            try Task.checkCancellation()
            try validateSession?()
            let interfaces = WifiDiagnosticSession.captureInterfaces()
            diagnostics.recordSnapshot(phase: "gen1-lan-before-tcp", interfaces: interfaces)
            if WifiConnectionDiagnostics.isGen1ClientIPv4(interfaces.selectedIPv4) {
                diagnostics.log("眼镜网段检查通过", detail: "selectedIPv4=\(interfaces.selectedIPv4 ?? "none") TCPVerified=false")
                return true
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        diagnostics.log("尚未获取眼镜 IPv4，引导手动连接并继续观察", detail: "connectionGrace=30s TCPAttempted=false")
        return false
    }

    static func disconnect(from ssid: String) {
        print("\(logTag) remove hotspot config ssid=\(ssid)")
        DebugLogStore.logWiFi("断开眼镜热点", detail: "ssid=\(ssid)", direction: .sent)
        removeTransferConfiguration(ssid)
        DebugLogStore.logWiFi("热点配置已移除", detail: "ssid=\(ssid)", direction: .received)
    }

    // MARK: - Apply

    private static func applyConfiguration(
        ssid: String,
        password: String,
        diagnostics: WifiDiagnosticSession,
        includePasswordInDiagnostics: Bool = true,
        joinOnce: Bool = true,
        timeout: TimeInterval? = nil,
        retainConfigurationUntilSessionCleanup: Bool = false,
        validateSession: (@MainActor () throws -> Void)? = nil
    ) async throws {
        try validateSession?()
        let started = ProcessInfo.processInfo.systemUptime
        let attemptID = UUID()
        configurationAttempts[ssid] = attemptID
        diagnostics.log(
            "请求系统加入热点",
            detail: "targetSSID=\(ssid.debugDescription)\npassword=\(includePasswordInDiagnostics ? password.debugDescription : "<redacted>")\npasswordUTF8Bytes=\(password.utf8.count)\nsecurity=\(password.isEmpty ? "open" : "WPA/WPA2")\njoinOnce=\(joinOnce)",
            direction: .sent
        )
        let result = CallbackResult()
        let timeoutTask = timeout.map { seconds in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                result.resolve(.failure(DeviceWifiError.joinFailed(L10n.t("系统加入热点请求超时", "System hotspot join request timed out"))))
            }
        }
        // iOS apply is not cancellable. Stop only our wait when the owning
        // device session shuts down; the late callback keeps its existing guard.
        let validationTask = validateSession.map { validate in
            Task { @MainActor in
                while !Task.isCancelled && !result.isResolved {
                    do {
                        try validate()
                        try await Task.sleep(nanoseconds: 250_000_000)
                    } catch {
                        guard !Task.isCancelled else { return }
                        diagnostics.log("设备会话已结束，提前停止等待系统加入热点", detail: "error=\(error.localizedDescription) systemApplyCancellationSupported=false removeConfiguration=false")
                        result.resolve(.failure(error))
                        return
                    }
                }
            }
        }
        defer { timeoutTask?.cancel(); validationTask?.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                result.install(continuation)
                let configuration: NEHotspotConfiguration
                if password.isEmpty {
                    configuration = NEHotspotConfiguration(ssid: ssid)
                } else {
                    configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
                }
                // A join-once network can be removed when iOS backgrounds the app.
                // Transfers using persistent joins retain it until explicit cleanup.
                configuration.joinOnce = joinOnce
                if !joinOnce { configuration.lifeTimeInDays = 1 }

                NEHotspotConfigurationManager.shared.apply(configuration) { error in
                    Task { @MainActor in
                        // apply cannot be cancelled. A late callback must not resurrect a
                        // cancelled persistent network or remove a newer attempt's network.
                        if result.isResolved || configurationAttempts[ssid] != attemptID {
                            if retainConfigurationUntilSessionCleanup,
                               configurationAttempts[ssid] == attemptID {
                                // A manual join can already be using this network. Only
                                // the owning import session may remove its configuration.
                                diagnostics.log("系统热点延迟回调已忽略，配置保留至会话清理", detail: "lateCallback=true removeConfiguration=false")
                                return
                            }
                            if configurationAttempts[ssid] == nil || configurationAttempts[ssid] == attemptID {
                                removeTransferConfiguration(ssid)
                            }
                            result.resolve(.failure(CancellationError()))
                            return
                        }
                        let elapsed = ProcessInfo.processInfo.systemUptime - started
                        let timing = "applyElapsed=\(String(format: "%.3f", elapsed))s"
                        diagnostics.recordSnapshot(phase: "apply-callback", force: true)
                        guard let error = error as NSError? else {
                            diagnostics.log("系统热点配置已应用，继续校验连接", detail: "\(timing)\nconfigurationApplied=true associationConfirmed=false; apply_success_does_not_prove_join_or_IP_ready", direction: .received)
                            result.resolve(.success(()))
                            return
                        }
                        let errorDetail = "\(timing)\nssid=\(ssid.debugDescription)\ndomain=\(error.domain)\ncode=\(error.code)\nerror=\(error.localizedDescription)"
                        guard error.domain == NEHotspotConfigurationErrorDomain else {
                            diagnostics.log("系统热点申请返回错误", detail: errorDetail, direction: .received)
                            result.resolve(.failure(DeviceWifiError.joinFailed(error.localizedDescription)))
                            return
                        }
                        switch error.code {
                        case NEHotspotConfigurationError.alreadyAssociated.rawValue:
                            diagnostics.log("系统报告已关联，继续校验网络", detail: errorDetail, direction: .received)
                            result.resolve(.success(()))
                        case NEHotspotConfigurationError.userDenied.rawValue:
                            diagnostics.log("用户拒绝加入热点", detail: errorDetail, direction: .received)
                            result.resolve(.failure(DeviceWifiError.userDenied))
                        default:
                            diagnostics.log("系统热点申请失败", detail: errorDetail, direction: .received)
                            result.resolve(.failure(DeviceWifiError.joinFailed(error.localizedDescription)))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in result.resolve(.failure(CancellationError())) }
        }
    }

    // MARK: - Readiness

    private struct ProbeEndpoint {
        let host: String
        let port: UInt16

        init(baseURL: String) {
            let url = URL(string: baseURL)
            host = url?.host ?? "192.168.0.1"
            port = UInt16(url?.port ?? 80)
        }
    }

    /// A missing SSID remains inconclusive; only a completed sample may use the IPv4 subnet fallback.
    private static func waitUntilReady(
        ssid: String,
        timeout: TimeInterval,
        diagnostics: WifiDiagnosticSession
    ) async throws -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + timeout
        let ssidObservation = SSIDObservation(diagnostics: diagnostics)
        defer { ssidObservation.cancel() }
        var loggedAddress: String?
        var loggedSSID: String?
        var hasLoggedSSID = false
        var lastValidation: String?
        var polls = 0

        diagnostics.log(
            "等待目标热点关联与 IPv4",
            detail: "targetSSID=\(ssid.debugDescription)\ntimeout=\(String(format: "%.1f", timeout))s pollInterval=\(readinessPollInterval)s\nTCPVerified=false HTTPResponseVerified=false"
        )

        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            ssidObservation.startReadIfNeeded()
            // The system SSID callback is not cancellable. Observe it without awaiting it so
            // cancellation and the monotonic deadline remain effective if the callback stalls.
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            try await Task.sleep(nanoseconds: UInt64(min(readinessPollInterval, remaining) * 1_000_000_000))
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime <= deadline else { break }
            polls += 1
            let currentSSID = diagnostics.currentSSID
            let interfaces = WifiDiagnosticSession.captureInterfaces()
            diagnostics.recordSnapshot(phase: "waiting-for-association-and-ip", interfaces: interfaces, probeAttempts: 0)
            if ssidObservation.hasCompletedRead && (!hasLoggedSSID || currentSSID != loggedSSID) {
                hasLoggedSSID = true
                loggedSSID = currentSSID
                diagnostics.log("当前 Wi-Fi 变化", detail: "currentSSID=\(currentSSID?.debugDescription ?? "unavailable")\ntargetSSID=\(ssid.debugDescription)", direction: .received)
            }

            if let address = interfaces.selectedIPv4 {
                if address != loggedAddress {
                    loggedAddress = address
                    diagnostics.log("Wi-Fi 获取 IPv4", detail: "address=\(address)", direction: .received)
                }
                guard ssidObservation.hasCompletedRead else { continue }
                let isTargetNetwork = WifiConnectionDiagnostics.matchesTargetNetwork(address: address, currentSSID: currentSSID, targetSSID: ssid)
                let validation = "ssid=\(currentSSID ?? "unavailable") address=\(address) matched=\(isTargetNetwork)"
                if validation != lastValidation {
                    lastValidation = validation
                    diagnostics.log(
                        isTargetNetwork ? "热点身份校验通过" : "当前网络不是目标热点",
                        detail: "currentSSID=\(currentSSID?.debugDescription ?? "unavailable")\ntargetSSID=\(ssid.debugDescription)\nipv4=\(address)\nmatched=\(isTargetNetwork)\nvalidationSource=\(currentSSID == nil ? "IPv4SubnetFallback" : "SSID")\nTCPVerified=false HTTPResponseVerified=false",
                        direction: .received
                    )
                }
                if isTargetNetwork {
                    diagnostics.recordSnapshot(phase: "association-and-ip-ready", interfaces: interfaces, probeAttempts: 0, force: true)
                    return true
                }
            } else if lastValidation != "no-ip" {
                lastValidation = "no-ip"
                diagnostics.log("Wi-Fi 尚未获取有效 IPv4", detail: "targetSSID=\(ssid.debugDescription); see_interface_snapshot_for_rejection_reasons", direction: .received)
            }
        }
        try Task.checkCancellation()
        // Preserve the final evidence before removing configuration or asking glasses to close Wi-Fi.
        let stage = diagnostics.recordSnapshot(phase: "timeout-before-cleanup", probeAttempts: 0, force: true)
        diagnostics.log(
            "热点等待超时诊断",
            detail: "lastObservedStage=\(stage)\nwaitElapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s configuredTimeout=\(timeout)s polls=\(polls)\nSSIDSampleCompleted=\(ssidObservation.hasCompletedRead)\nprobeAttempts=0 lastProbeSucceeded=notAttempted\ncallerTaskCancelled=\(Task.isCancelled)\nfailureBoundary=association-or-IP-not-confirmed\nTCPVerified=false HTTPResponseVerified=false; snapshot_does_not_identify_AP_authentication_or_DHCP_root_cause",
            direction: .received
        )
        return false
    }

    /// Keeps at most one system SSID read pending while the caller polls and remains cancellable.
    @MainActor
    private final class SSIDObservation {
        private let diagnostics: WifiDiagnosticSession
        private var pendingRead: Task<Void, Never>?
        private(set) var hasCompletedRead = false

        init(diagnostics: WifiDiagnosticSession) {
            self.diagnostics = diagnostics
        }

        func startReadIfNeeded() {
            guard pendingRead == nil else { return }
            hasCompletedRead = false
            pendingRead = Task { @MainActor [weak self, diagnostics] in
                _ = await diagnostics.fetchCurrentSSID()
                guard !Task.isCancelled else { return }
                self?.hasCompletedRead = true
                self?.pendingRead = nil
            }
        }

        func cancel() {
            pendingRead?.cancel()
            pendingRead = nil
        }
    }

    /// Main-actor callbacks and cancellation may race; resume the caller exactly once.
    @MainActor
    private final class CallbackResult {
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?
        var isResolved: Bool { result != nil }

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            if let result {
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
            }
        }

        func resolve(_ result: Result<Void, Error>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
