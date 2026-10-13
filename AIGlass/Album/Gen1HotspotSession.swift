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

    /// The manager owns cleanup beyond cancellation, timeout and session teardown.
    func close() async -> Gen1HotspotCleanup.Outcome {
        guard needsCleanup else { return .settled }
        return await ble.closeGen1Hotspot(identity)
    }
}
