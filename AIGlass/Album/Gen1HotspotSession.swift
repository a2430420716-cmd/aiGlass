import Combine
import Foundation

/// An AP business session owns 0x37 replies; the recording handler must not consume them.
@MainActor
final class Gen1HotspotSession {
    let identity: Gen1APImportIdentity
    private let ble: AstraA1BleManager
    private var subscription: AnyCancellable?
    private var response: Result<Gen1HotspotCredentials, Error>?
    private var needsCleanup = false

    init(ble: AstraA1BleManager, identity: Gen1APImportIdentity) {
        self.ble = ble
        self.identity = identity
    }

    func open(timeout: TimeInterval = 20) async throws -> Gen1HotspotCredentials {
        do {
            return try await openOnce(timeout: timeout)
        } catch Gen1APImportError.hotspotTimeout {
            try Task.checkCancellation()
            guard ble.isGen1MediaImportCurrent(identity) else { throw Gen1APImportError.targetChanged }
            DebugLogStore.logWiFi("一代：热点信息超时，准备唯一一次自动重试", detail: "target=\(identity.targetID) retry=1/1 next=close_0x38_then_fresh_standby")
            let reportSequenceBeforeClose = ble.deviceRuntimeStatusReportSequence
            guard await close() == .settled else { throw Gen1APImportError.hotspotCleanupPending }
            needsCleanup = false
            try Task.checkCancellation()
            guard ble.isGen1MediaImportCurrent(identity) else { throw Gen1APImportError.targetChanged }
            return try await openOnce(timeout: timeout, requiresFreshStandby: true, reportSequenceBeforeClose: reportSequenceBeforeClose)
        }
    }

    private func openOnce(timeout: TimeInterval, requiresFreshStandby: Bool = false, reportSequenceBeforeClose: Int? = nil) async throws -> Gen1HotspotCredentials {
        try await requireStandbyBeforeOpen(requiresFresh: requiresFreshStandby, reportSequenceBeforeClose: reportSequenceBeforeClose)
        response = nil
        subscription = ble.gen1ControlSubject.sink { [weak self] frame in
            guard let self, frame.command == Gen1Commands.openHotspot,
                  self.ble.isGen1MediaImportCurrent(self.identity),
                  self.ble.deviceBluetoothIdentifier == self.identity.targetID.uuidString,
                  self.response == nil else { return }
            // BUSY explicitly rejects this open. Do not send a shutdown that
            // could interrupt the operation which made the glasses busy.
            if frame.payload == Data([0xE3]) { self.needsCleanup = false }
            self.response = Result { try Gen1APImportProtocol.credentials(from: frame.payload) }
        }
        defer { subscription?.cancel(); subscription = nil }
        try Task.checkCancellation()
        guard ble.isGen1MediaImportCurrent(identity),
              ble.sendGen1Command(command: Gen1Commands.openHotspot) else {
            throw Gen1APImportError.sendFailed
        }
        needsCleanup = true
        DebugLogStore.logWiFi("一代：已请求开启热点", detail: "command=0x37 payloadBytes=0 target=\(identity.targetID)")
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard ble.isGen1MediaImportCurrent(identity) else { throw Gen1APImportError.targetChanged }
            if let response { return try response.get() }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Gen1APImportError.hotspotTimeout
    }

    /// Prefer fresh query/notification evidence; change-only firmware can fall
    /// back to its last reported standby if the current session is still idle.
    private func requireStandbyBeforeOpen(requiresFresh: Bool = false, reportSequenceBeforeClose: Int? = nil) async throws {
        var latestStatus: Gen1DomainDeviceStatus?
        // A fresh idle report received during the confirmed close also counts;
        // change-only firmware may not repeat it in response to another query.
        if let sequence = reportSequenceBeforeClose,
           ble.deviceRuntimeStatusReportSequence > sequence,
           ble.deviceRuntimeStatus == .standby,
           ble.lastReportedDeviceRuntimeStatus == .standby {
            latestStatus = .standby
        }
        var latestCommand: UInt8?
        let observation = ble.gen1ControlSubject.sink { [weak self] frame in
            guard let self, self.ble.isGen1MediaImportCurrent(self.identity),
                  self.ble.deviceBluetoothIdentifier == self.identity.targetID.uuidString,
                  frame.payload.count == 1,
                  let rawStatus = frame.payload.first,
                  (frame.command == Gen1Commands.deviceStatusQuery
                    || frame.command == Gen1Commands.deviceStatusChanged) else { return }
            latestCommand = frame.command
            latestStatus = Gen1DeviceStatusMapper.toDomainStatus(rawStatus)
        }
        defer { observation.cancel() }
        try Task.checkCancellation()
        guard ble.isGen1MediaImportCurrent(identity) else { throw Gen1APImportError.targetChanged }
        DebugLogStore.logWiFi("一代：开启热点前查询最新设备状态", detail: "command=0x72 target=\(identity.targetID) cachedStatus=\(ble.deviceRuntimeStatus) timeout=3s")
        guard ble.sendGen1Command(command: Gen1Commands.deviceStatusQuery) else {
            throw Gen1APImportError.statusUnconfirmed
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard ble.isGen1MediaImportCurrent(identity) else { throw Gen1APImportError.targetChanged }
            if let latestStatus {
                DebugLogStore.logWiFi("一代：开启热点前状态确认", detail: "freshDeviceReport=true sourceCommand=\(latestCommand.map { String(format: "0x%02X", $0) } ?? "none") status=\(latestStatus) allowOpen=\(latestStatus == .standby) target=\(identity.targetID)")
                try Gen1APImportProtocol.requireStandby(fresh: latestStatus, current: .unknown, lastReported: .unknown)
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        guard ble.isGen1MediaImportCurrent(identity) else { throw Gen1APImportError.targetChanged }
        if requiresFresh {
            DebugLogStore.logWiFi("一代：自动重试未取得新的空闲回报，停止重开热点", detail: "target=\(identity.targetID) retry=1/1 openSent=false cachedStandbyNotAccepted=true")
            throw Gen1APImportError.statusUnconfirmed
        }
        let current = Gen1DomainDeviceStatus(rawValue: ble.deviceRuntimeStatus.rawValue) ?? .unknown
        let reported = Gen1DomainDeviceStatus(rawValue: ble.lastReportedDeviceRuntimeStatus.rawValue) ?? .unknown
        do {
            try Gen1APImportProtocol.requireStandby(fresh: latestStatus, current: current, lastReported: reported)
            DebugLogStore.logWiFi("一代：状态查询无回包，兼容设备已报告的空闲状态", detail: "target=\(identity.targetID) current=\(current) lastReported=\(reported) freshReport=false fallback=reportedStandby deviceBusyReplyStillRequired=true")
        } catch {
            DebugLogStore.logWiFi("一代：状态未满足空闲条件，未开启热点", detail: "target=\(identity.targetID) current=\(current) lastReported=\(reported) openSent=false wifiApply=false error=\(error.localizedDescription)")
            throw error
        }
    }

    /// The manager owns cleanup beyond cancellation, timeout and session teardown.
    func close() async -> Gen1HotspotCleanup.Outcome {
        guard needsCleanup else { return .settled }
        return await ble.closeGen1Hotspot(identity)
    }
}
