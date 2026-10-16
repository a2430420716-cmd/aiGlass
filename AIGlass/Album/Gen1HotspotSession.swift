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
        try await requireFreshStandby()
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

    /// Cached idle/busy values can outlive the preceding AP session. Require a
    /// fresh query response before starting another AP; notifications alone do not authorize it.
    private func requireFreshStandby() async throws {
        var queryAnswered = false
        var latestStatus: Gen1DomainDeviceStatus?
        let observation = ble.gen1ControlSubject.sink { [weak self] frame in
            guard let self, self.ble.isGen1MediaImportCurrent(self.identity),
                  self.ble.deviceBluetoothIdentifier == self.identity.targetID.uuidString,
                  frame.payload.count == 1,
                  let rawStatus = frame.payload.first,
                  (frame.command == Gen1Commands.deviceStatusQuery
                    || frame.command == Gen1Commands.deviceStatusChanged) else { return }
            if frame.command == Gen1Commands.deviceStatusQuery { queryAnswered = true }
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
            if queryAnswered, let latestStatus {
                DebugLogStore.logWiFi("一代：开启热点前状态确认", detail: "freshQuery=true status=\(latestStatus) allowOpen=\(latestStatus == .standby) target=\(identity.targetID)")
                guard latestStatus != .unknown else { throw Gen1APImportError.statusUnconfirmed }
                guard latestStatus == .standby else { throw Gen1APImportError.deviceBusy }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        DebugLogStore.logWiFi("一代：状态查询超时，未开启热点", detail: "target=\(identity.targetID) openSent=false wifiApply=false")
        throw Gen1APImportError.statusUnconfirmed
    }

    /// The manager owns cleanup beyond cancellation, timeout and session teardown.
    func close() async -> Gen1HotspotCleanup.Outcome {
        guard needsCleanup else { return .settled }
        return await ble.closeGen1Hotspot(identity)
    }
}
