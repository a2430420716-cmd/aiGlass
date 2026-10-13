import Foundation

/// Correlates one import's checkpoints with its hotspot and TCP diagnostics.
/// Reads app state only; never sends commands or controls the import.
@MainActor
final class ImportDiagnosticContext {
    let id = UUID().uuidString
    let kind: String
    private let targetPeripheral: String
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private weak var ble: AstraA1BleManager?

    init(kind: String, ble: AstraA1BleManager) {
        self.kind = kind
        self.ble = ble
        targetPeripheral = ble.deviceBluetoothIdentifier ?? "unavailable"
    }

    var connectionContext: String {
        "import=\(kind) targetPeripheral=\(targetPeripheral)"
    }

    var deviceEvidence: String {
        guard let ble else { return "deviceEvidence=unavailable" }
        return "targetPeripheral=\(targetPeripheral) currentPeripheral=\(ble.deviceBluetoothIdentifier ?? "unavailable")"
            + " bleReady=\(ble.isReady) bleState=\(String(describing: ble.connectionState))"
            + " cachedRuntimeStatus=\(String(describing: ble.deviceRuntimeStatus))"
            + " cachedVer28=\(ble.deviceVersion2800 ?? "unavailable") cachedVer63=\(ble.deviceVersion6350 ?? "unavailable")"
            + " deviceEvidenceSource=app_state_not_fresh_device_query"
    }

    func log(_ title: String, detail: String = "", direction: DebugLogStore.Direction = .event) {
        let now = ProcessInfo.processInfo.systemUptime
        DebugLogStore.logWiFi(
            title,
            detail: "importDiagnosticVersion=1 diagnosticID=\(id) import=\(kind) uptime=\(String(format: "%.3f", now)) importElapsed=\(String(format: "%.3f", now - startedAt))s\n\(deviceEvidence)\n\(detail)",
            direction: direction
        )
    }
}
