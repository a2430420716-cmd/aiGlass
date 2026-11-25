import Foundation

@main enum PairingDeviceNamePolicyTests {
    static func main() {
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            assertions += 1
        }
        check(!PairingDeviceNamePolicy.matchesModel("L2", deviceName: "L1 0361"),
              "Same protocol/generation must not admit a different selected sales model")
        for model in ["L1", "L2", "L3", "G5T71"] {
            check(PairingDeviceNamePolicy.matchesModel(model, deviceName: "\(model.lowercased()) 0361"),
                  "Selected raw model_name matches its own broadcast regardless of case")
        }
        check(PairingDeviceNamePolicy.matchesModel("L1", deviceName: "MOCO L1 0361"),
              "Containment follows Android, including names with a brand prefix")
        check(!PairingDeviceNamePolicy.matchesModel("G5K61", deviceName: "L1 0361"),
              "A generation hint is not an alternative sales model name")
        check(!PairingDeviceNamePolicy.matchesModel("L2", deviceName: "My glasses"),
              "A UI alias must not broaden discovery to every device of the same generation")
        check(!PairingDeviceNamePolicy.matchesModel("L2", deviceName: " \n "), "Nameless devices stay hidden")
        check(PairingDeviceNamePolicy.matchesModel(nil, deviceName: "L2 0361"), "No selected filter keeps Android compatibility")
        check(PairingDeviceNamePolicy.discoveredName(advertised: " L2 0361 ", cached: "L1 0361") == "L2 0361",
              "Fresh advertisement takes precedence over CoreBluetooth's cached name")
        check(PairingDeviceNamePolicy.discoveredName(advertised: " ", cached: " L3 0361 ") == "L3 0361",
              "Blank advertisement falls back to the cached name")
        check(PairingDeviceNamePolicy.discoveredName(advertised: nil, cached: nil).isEmpty,
              "Missing names cannot become invented model labels")
        let fresh = PairingDeviceNamePolicy.discoveredName(advertised: "L2 0361", cached: "L1 0361")
        check(PairingDeviceNamePolicy.matchesModel("L2", deviceName: fresh), "Filtering uses the displayed fresh name")
        check(!PairingDeviceNamePolicy.matchesModel("L1", deviceName: fresh), "Cached stale name cannot select another model")

        let scan = PairingNameScanProbe()
        let wrong = CBPeripheral(identifier: UUID(), name: "L1 0361")
        scan.discover(wrong, advertisementData: ["generation": DeviceGeneration.gen1G5K61], rssi: -30)
        check(scan.discoveredPairingDevices.isEmpty && scan.queued.isEmpty,
              "Production scan must exclude L1 when L2 is selected, even with matching device_type")
        let renamed = CBPeripheral(identifier: UUID(), name: "L1 0361")
        scan.discover(renamed, advertisementData: [CBAdvertisementDataLocalNameKey: "L2 0361",
                       "generation": DeviceGeneration.gen1G5K61], rssi: -40)
        check(scan.discoveredPairingDevices.first?.displayName == "L2 0361",
              "Production admission and registration use the fresh name together")
        check(scan.discoveredPairingDevices.first?.id == renamed.identifier,
              "A display change preserves the exact peripheral identity")
        scan.discover(renamed, advertisementData: [CBAdvertisementDataLocalNameKey: "L2 9999",
                       "generation": DeviceGeneration.gen1G5K61], rssi: -80)
        check(scan.discoveredPairingDevices.count == 1 && scan.discoveredPairingDevices[0].displayName == "L2 9999",
              "A weaker later signal still updates the same device's name")
        check(scan.discoveredPairingDevices[0].rssi == -40, "Name changes retain the best known RSSI")
        let noServiceWrong = CBPeripheral(identifier: UUID(), name: "L1 0079")
        scan.discover(noServiceWrong, advertisementData: [:], rssi: -35)
        check(scan.queued.isEmpty, "Wrong model must not enter the GATT probe queue")
        let noServiceMatch = CBPeripheral(identifier: UUID(), name: "L2 0079")
        scan.discover(noServiceMatch, advertisementData: [:], rssi: -35)
        check(scan.queued == [noServiceMatch.identifier], "Matching model without advertised services still gets GATT verification")
        check(scan.pairingAdvertisedNames[noServiceMatch.identifier] == "L2 0079",
              "Names stay keyed by UUID through GATT probing")
        let conflicting = CBPeripheral(identifier: UUID(), name: "L2 0080")
        scan.discover(conflicting, advertisementData: ["generation": DeviceGeneration.gen2], rssi: -30)
        check(scan.discoveredPairingDevices.count == 1,
              "Name match must not override incompatible API device_type and GATT generation")
        scan.pairingDeviceTypeFilter = nil
        scan.discover(noServiceMatch, advertisementData: [:], rssi: -35)
        check(scan.discoveredPairingDevices.contains { $0.id == noServiceMatch.identifier },
              "Old responses without device_type keep model-name matching")
        check(APIDeviceType.firstGeneration.generation == .gen1G5K61 && APIDeviceType.secondGeneration.generation == .gen2,
              "L2/L3 names never replace the API generation contract")
        print("Pairing device names: \(assertions) assertions passed")
    }
}
