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

        let presentation = PairingPresentationProbe()
        let backgroundStates: [AstraA1ConnectionState] = [
            .scanning, .connecting, .discoveringServices, .enablingNotifications, .ready, .disconnected
        ]
        for state in backgroundStates {
            presentation.astraA1BleManager.connectionState = state
            check(!presentation.isPairingSheetConnecting,
                  "Background GATT probes must never become user-confirmed pairing")
            check(presentation.pairingSheetLoadingText == "Searching for devices…",
                  "Automatic candidate checks keep the searching explanation")
            let sheet = PairingSheetVisibilityProbe(devices: scan.discoveredPairingDevices,
                isConnecting: presentation.isPairingSheetConnecting, isBinding: presentation.isBindingDevice)
            check(sheet.showsDeviceList, "Known UUIDs remain visible/selectable while another candidate is probed")
        }
        presentation.userConfirmedPairingDevice = true
        check(presentation.isPairingSheetConnecting, "An explicit Pair tap locks presentation to pairing")
        check(presentation.pairingSheetLoadingText == "Pairing", "Explicit selection still shows pairing progress")
        check(!PairingSheetVisibilityProbe(devices: scan.discoveredPairingDevices,
            isConnecting: presentation.isPairingSheetConnecting, isBinding: false).showsDeviceList,
              "User-confirmed pairing hides the list to prevent a second selection")
        presentation.userConfirmedPairingDevice = false
        presentation.isBindingDevice = true
        check(presentation.isPairingSheetConnecting && presentation.pairingSheetLoadingText == "Pairing device...",
              "Backend binding continues to show its own progress")
        presentation.isBindingDevice = false
        check(!presentation.isPairingSheetConnecting, "Cancelling/restoring search releases the pairing presentation")
        presentation.astraA1BleManager.connectionState = .bluetoothUnavailable("Bluetooth off")
        check(presentation.pairingSheetLoadingText == "Bluetooth off", "Bluetooth permission/power guidance remains visible")
        check(!PairingSheetVisibilityProbe(devices: [], isConnecting: false, isBinding: false).showsDeviceList,
              "Empty searches retain their loading presentation")

        let ordering = PairingNameScanProbe()
        let first = CBPeripheral(identifier: UUID(), name: "L2 0001")
        let second = CBPeripheral(identifier: UUID(), name: "L2 0002")
        ordering.discover(first, advertisementData: ["generation": DeviceGeneration.gen1G5K61], rssi: -50)
        ordering.discover(second, advertisementData: ["generation": DeviceGeneration.gen1G5K61], rssi: -60)
        ordering.discover(second, advertisementData: ["generation": DeviceGeneration.gen1G5K61,
                           CBAdvertisementDataLocalNameKey: "L2 renamed"], rssi: -20)
        check(ordering.discoveredPairingDevices.map(\.id) == [first.identifier, second.identifier],
              "RSSI changes cannot move rows under the user's Pair button")
        check(ordering.discoveredPairingDevices[1].displayName == "L2 renamed"
              && ordering.discoveredPairingDevices[1].rssi == -20,
              "A stable row still updates its name and best signal without replacing its UUID")

        // Product series come from model_name, with no generation-to-series mapping.
        let series = ["L1", "L2", "L3", "M1", "X9 Pro"]
        for type in [APIDeviceType.firstGeneration, .secondGeneration] {
            for model in series {
                let candidateScan = PairingNameScanProbe()
                candidateScan.pairingModelNameFilter = model
                candidateScan.pairingDeviceTypeFilter = type
                for other in series where other != model {
                    candidateScan.discover(CBPeripheral(identifier: UUID(), name: "\(other) 0031"),
                        advertisementData: ["generation": type.generation], rssi: -25)
                    candidateScan.discover(CBPeripheral(identifier: UUID(), name: "\(other) 0032"),
                        advertisementData: [:], rssi: -25)
                }
                check(candidateScan.discoveredPairingDevices.isEmpty && candidateScan.queued.isEmpty,
                      "Same device_type cannot admit or probe another product: \(model)")
                let device = CBPeripheral(identifier: UUID(), name: "\(model.lowercased()) 0033")
                candidateScan.discover(device, advertisementData: ["generation": type.generation], rssi: -35)
                check(candidateScan.discoveredPairingDevices.map(\.id) == [device.identifier],
                      "Arbitrary current model works with its own protocol generation")
                let pending = CBPeripheral(identifier: UUID(), name: "\(model) 0034")
                candidateScan.discover(pending, advertisementData: [:], rssi: -40)
                check(candidateScan.queued == [pending.identifier], "Own model without services still requires a GATT probe")
                let opposite: DeviceGeneration = type == .firstGeneration ? .gen2 : .gen1G5K61
                candidateScan.discover(CBPeripheral(identifier: UUID(), name: "\(model) 0035"),
                    advertisementData: ["generation": opposite], rssi: -20)
                check(candidateScan.discoveredPairingDevices.count == 1, "Own series cannot bypass conflicting GATT protocol")
                check(candidateScan.pairWithDiscoveredDevice(id: device.identifier), "Own verified series remains selectable")
                check(candidateScan.connectedIDs == [device.identifier], "Pairing connects the exact selected UUID")
            }
        }

        let finalAdmission = PairingNameScanProbe()
        let staleL1 = CBPeripheral(identifier: UUID(), name: "L1 0036")
        finalAdmission.addVerifiedPairingDevice(staleL1, displayName: "L1 0036", rssi: -20)
        check(finalAdmission.discoveredPairingDevices.isEmpty && finalAdmission.discoveredPeripherals.isEmpty,
              "Final registration cannot bypass the selected series even after a delayed probe")
        let liveL2 = CBPeripheral(identifier: UUID(), name: "L1 cached")
        finalAdmission.discover(liveL2, advertisementData: ["generation": DeviceGeneration.gen1G5K61,
                              CBAdvertisementDataLocalNameKey: "L2 0037"], rssi: -35)
        finalAdmission.pairingModelNameFilter = "M1"
        check(!finalAdmission.pairWithDiscoveredDevice(id: liveL2.identifier)
              && finalAdmission.connectedIDs.isEmpty && finalAdmission.stoppedProbes == 0,
              "A stale tap from the previous model cannot stop probing or connect")
        finalAdmission.pairingModelNameFilter = "L2"
        check(finalAdmission.pairWithDiscoveredDevice(id: liveL2.identifier),
              "Latest matching advertisement wins over an old cached peripheral name at selection")
        let hidden = CBPeripheral(identifier: UUID(), name: "L2 unverified")
        finalAdmission.discoveredPeripherals[hidden.identifier] = hidden
        check(!finalAdmission.pairWithDiscoveredDevice(id: hidden.identifier), "Unverified cache entries cannot be selected")

        let rows = PairingPresentationProbe()
        let rawRows = series.map { DiscoveredBLEDevice(id: UUID(), displayName: "\($0) 0040", rssi: -40) }
        rows.astraA1BleManager.discoveredPairingDevices = rawRows
        for (index, model) in series.enumerated() {
            rows.selectedAPIModelName = model
            check(rows.discoveredPairingDevices == [rawRows[index]],
                  "Search presentation preserves the live name and only the selected series")
        }
        rows.selectedAPIModelName = "M1"
        rows.pairWithDiscoveredDevice(id: rawRows[1].id)
        check(rows.astraA1BleManager.selectedIDs.isEmpty && !rows.userConfirmedPairingDevice,
              "Coordinator rejects a stale L2 row after selecting M1")
        rows.pairWithDiscoveredDevice(id: rawRows[3].id)
        check(rows.astraA1BleManager.selectedIDs == [rawRows[3].id] && rows.userConfirmedPairingDevice,
              "Coordinator forwards only the current matching UUID")
        rows.selectedAPIModelName = nil
        check(rows.discoveredPairingDevices.isEmpty, "Missing selection cannot display all devices of a generation")
        print("Pairing device names: \(assertions) assertions passed")
    }
}
