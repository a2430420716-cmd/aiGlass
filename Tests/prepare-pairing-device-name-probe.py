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
))
probe = """
import Foundation
let CBAdvertisementDataLocalNameKey = "local-name"
let CBAdvertisementDataIsConnectable = "connectable"
struct CBPeripheral { let identifier: UUID; let name: String? }
enum L10n { static func t(_ zh: String, _ en: String) -> String { en } }
""" + block(text, 'struct DiscoveredBLEDevice:') + """
final class PairingNameScanProbe {
    var pairingModelNameFilter: String? = "L2"
    var pairingDeviceTypeFilter: APIDeviceType? = .firstGeneration
    var pairingAdvertisedNames: [UUID: String] = [:]
    var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    var discoveredPairingDevices: [DiscoveredBLEDevice] = []
    var queued: [UUID] = []
    var isManualPairingScan = true
    let logTag = "[scan-test]"
    func advertisedProtocolGeneration(_ data: [String: Any]) -> DeviceGeneration {
        data["generation"] as? DeviceGeneration ?? .unknown
    }
    func enqueueProbeCandidate(_ peripheral: CBPeripheral, rssi: NSNumber) { queued.append(peripheral.identifier) }
    func scheduleProbeStart() {}
    func discover(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
""" + admission + '\n}\n' + methods + '\n}\n'
Path(sys.argv[1]).write_text(probe, encoding='utf-8')
