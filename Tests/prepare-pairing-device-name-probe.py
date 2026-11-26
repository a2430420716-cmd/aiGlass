"""Exercise production scan admission and name registration without CoreBluetooth IO."""
from pathlib import Path
import sys

repo = Path(__file__).resolve().parents[1]
source = Path(sys.argv[2]) if len(sys.argv) > 2 else repo / 'AIGlass/Bluetooth/AstraA1/AstraA1BleManager.swift'
text = source.read_text(encoding='utf-8')


def block(source, marker):
    start = source.index(marker)
    cursor = source.index('{', start) + 1
    depth = 1
    while depth:
        if source[cursor] == '{':
            depth += 1
        elif source[cursor] == '}':
            depth -= 1
        cursor += 1
    return source[start:cursor]


scan = text[text.index('        didDiscover peripheral: CBPeripheral,'):]
admission = block(scan, '            if isManualPairingScan {')
methods = '\n'.join(block(text, marker).replace('private func ', 'func ', 1) for marker in (
    '    private func resolvedName(', '    private func nameMatchesPairingModelName(',
    '    private func registerNameMatchedPairingDevice(', '    private func addVerifiedPairingDevice(',
    '    func pairWithDiscoveredDevice(id:',
))
coordinator_source = Path(sys.argv[3]) if len(sys.argv) > 3 else repo / 'AIGlass/PairingFlow.swift'
coordinator = coordinator_source.read_text(encoding='utf-8')
presentation = '\n'.join(block(coordinator, marker) for marker in (
    '    var isPairingSheetConnecting:', '    var pairingSheetLoadingText:',
    '    var discoveredPairingDevices:', '    func pairWithDiscoveredDevice(id:',
))
sheet = (repo / 'AIGlass/DeviceSearchingSheet.swift').read_text(encoding='utf-8')
visibility = block(sheet, '    private var showsDeviceList:').replace('private var ', 'var ', 1)
probe = """
import Foundation
let CBAdvertisementDataLocalNameKey = "local-name"
let CBAdvertisementDataIsConnectable = "connectable"
struct CBPeripheral { let identifier: UUID; let name: String? }
enum L10n { static func t(_ zh: String, _ en: String) -> String { en } }
""" + block(text, 'struct DiscoveredBLEDevice:') + '\n' + block(text, 'enum PairingProbeStartPolicy {') + """
final class PairingNameScanProbe {
    var pairingModelNameFilter: String? = "L2"
    var pairingDeviceTypeFilter: APIDeviceType? = .firstGeneration
    var pairingAdvertisedNames: [UUID: String] = [:]
    var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    var discoveredPairingDevices: [DiscoveredBLEDevice] = []
    var queued: [UUID] = []
    var isManualPairingScan = true
    var isPairingSessionActive = true
    var isUserInitiatedPairingConnect = false
    var userPairingTargetID: UUID?
    var userPairingRetryCount = 0
    var connectedIDs: [UUID] = []
    var stoppedProbes = 0
    let logTag = "[scan-test]"
    func connectLog(_ event: String, detail: String) {}
    func advertisedProtocolGeneration(_ data: [String: Any]) -> DeviceGeneration {
        data["generation"] as? DeviceGeneration ?? .unknown
    }
    func enqueueProbeCandidate(_ peripheral: CBPeripheral, rssi: NSNumber) { queued.append(peripheral.identifier) }
    func scheduleProbeStart() {}
    func stopPairingListProbe() { stoppedProbes += 1 }
    func connectForUserPairing(to peripheral: CBPeripheral) { connectedIDs.append(peripheral.identifier) }
    func discover(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let callbackUptime = ProcessInfo.processInfo.systemUptime
""" + admission + '\n}\n' + methods + '\n}\n' + block(text, 'enum AstraA1ConnectionState:') + """
final class PairingConnectionProbe {
    var connectionState: AstraA1ConnectionState = .scanning
    var statusMessage = ""
    var discoveredPairingDevices: [DiscoveredBLEDevice] = []
    var selectedIDs: [UUID] = []
    func pairWithDiscoveredDevice(id: UUID) -> Bool { selectedIDs.append(id); return true }
}
final class PairingPresentationProbe {
    var isBindingDevice = false
    var userConfirmedPairingDevice = false
    var pairingModel: GlassDeviceModel? = .luminaL1
    var selectedAPIModelName: String? = "L2"
    var bindStatusMessage: String?
    var pairingAlertMessage: String?
    var waitedForID: UUID?
    let astraA1BleManager = PairingConnectionProbe()
    func isBindFailureOrAlreadyBound(_ message: String) -> Bool { false }
    func isPeripheralAlreadyBound(_ id: UUID) -> Bool { false }
    func startDeviceIdentityTimeout(peripheralID: UUID) { waitedForID = peripheralID }
""" + presentation + """
}
struct PairingSheetVisibilityProbe {
    let devices: [DiscoveredBLEDevice]
    let isConnecting: Bool
    let isBinding: Bool
""" + visibility + '\n}\n'
Path(sys.argv[1]).write_text(probe, encoding='utf-8')
