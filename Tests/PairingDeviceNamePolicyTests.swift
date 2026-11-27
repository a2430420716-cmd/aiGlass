import Foundation

@main enum PairingDeviceNamePolicyTests {
    static func main() {
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            assertions += 1
        }
        check(PairingProbeStartPolicy.delay(isManualPairing: true, hasScheduledStart: false, defaultDelay: 1.5) == 0.2,
              "The first matching pairing candidate starts verification after 0.2 seconds")
        var pairingDeadline: TimeInterval?
        for arrival in [0.0, 0.05, 0.1, 0.15, 0.19] {
            if let delay = PairingProbeStartPolicy.delay(
                isManualPairing: true, hasScheduledStart: pairingDeadline != nil, defaultDelay: 1.5
            ) {
                pairingDeadline = arrival + delay
            }
        }
        check(pairingDeadline == 0.2, "Repeated advertisements cannot postpone the first pending probe")
        check(PairingProbeStartPolicy.delay(isManualPairing: true, hasScheduledStart: true, defaultDelay: 1.5) == nil,
              "An already armed pairing timer is retained")
        check(PairingProbeStartPolicy.delay(isManualPairing: true, hasScheduledStart: false, defaultDelay: 1.5) == 0.2,
              "After firing or cancellation a new candidate can arm another timer")
        for pending in [false, true] {
            check(PairingProbeStartPolicy.delay(isManualPairing: false, hasScheduledStart: pending, defaultDelay: 1.5) == 1.5,
                  "Background discovery retains its existing debounce")
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
        scan.discover(wrong, advertisementData: ["generation": DeviceGeneration.gen1G5K61,
                      CBAdvertisementDataLocalNameKey: "L1 0361"], rssi: -30)
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
        scan.discover(noServiceWrong, advertisementData: [CBAdvertisementDataLocalNameKey: "L1 0079"], rssi: -35)
        check(scan.queued.isEmpty, "Wrong model must not enter the GATT probe queue")
        let noServiceMatch = CBPeripheral(identifier: UUID(), name: "L2 0079")
        scan.discover(noServiceMatch, advertisementData: [CBAdvertisementDataLocalNameKey: "L2 0079"], rssi: -35)
        check(scan.queued == [noServiceMatch.identifier], "Matching model without advertised services still gets GATT verification")
        check(scan.pairingAdvertisedNames[noServiceMatch.identifier] == "L2 0079",
              "Names stay keyed by UUID through GATT probing")
        let conflicting = CBPeripheral(identifier: UUID(), name: "L2 0080")
        scan.discover(conflicting, advertisementData: ["generation": DeviceGeneration.gen2,
                      CBAdvertisementDataLocalNameKey: "L2 0080"], rssi: -30)
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
        ordering.discover(first, advertisementData: ["generation": DeviceGeneration.gen1G5K61,
                          CBAdvertisementDataLocalNameKey: "L2 0001"], rssi: -50)
        ordering.discover(second, advertisementData: ["generation": DeviceGeneration.gen1G5K61,
                          CBAdvertisementDataLocalNameKey: "L2 0002"], rssi: -60)
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
                        advertisementData: ["generation": type.generation,
                                            CBAdvertisementDataLocalNameKey: "\(other) 0031"], rssi: -25)
                    candidateScan.discover(CBPeripheral(identifier: UUID(), name: "\(other) 0032"),
                        advertisementData: [CBAdvertisementDataLocalNameKey: "\(other) 0032"], rssi: -25)
                }
                check(candidateScan.discoveredPairingDevices.isEmpty && candidateScan.queued.isEmpty,
                      "Same device_type cannot admit or probe another product: \(model)")
                let device = CBPeripheral(identifier: UUID(), name: "\(model.lowercased()) 0033")
                candidateScan.discover(device, advertisementData: ["generation": type.generation,
                                       CBAdvertisementDataLocalNameKey: "\(model.lowercased()) 0033"], rssi: -35)
                check(candidateScan.discoveredPairingDevices.map(\.id) == [device.identifier],
                      "Arbitrary current model works with its own protocol generation")
                let pending = CBPeripheral(identifier: UUID(), name: "\(model) 0034")
                candidateScan.discover(pending, advertisementData: [CBAdvertisementDataLocalNameKey: "\(model) 0034"], rssi: -40)
                check(candidateScan.queued == [pending.identifier], "Own model without services still requires a GATT probe")
                let opposite: DeviceGeneration = type == .firstGeneration ? .gen2 : .gen1G5K61
                candidateScan.discover(CBPeripheral(identifier: UUID(), name: "\(model) 0035"),
                    advertisementData: ["generation": opposite,
                                        CBAdvertisementDataLocalNameKey: "\(model) 0035"], rssi: -20)
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

        let renamedScan = PairingNameScanProbe()
        renamedScan.pairingModelNameFilter = "L1"
        let device0344 = CBPeripheral(identifier: UUID(), name: "L1 0344")
        renamedScan.discover(device0344, advertisementData: ["generation": DeviceGeneration.gen1G5K61], rssi: -30)
        check(renamedScan.discoveredPairingDevices.isEmpty && renamedScan.queued.isEmpty,
              "A cached L1 name without a current Local Name cannot establish the model")
        renamedScan.discover(device0344, advertisementData: ["generation": DeviceGeneration.gen1G5K61,
                             CBAdvertisementDataLocalNameKey: "L2 0344"], rssi: -30)
        check(renamedScan.discoveredPairingDevices.isEmpty && renamedScan.queued.isEmpty &&
              renamedScan.pairingAdvertisedNames[device0344.identifier] == "L2 0344",
              "L1 search records but rejects the current L2 name despite cached L1")
        renamedScan.discover(device0344, advertisementData: ["generation": DeviceGeneration.gen1G5K61], rssi: -25)
        check(renamedScan.discoveredPairingDevices.isEmpty && renamedScan.queued.isEmpty,
              "A later nameless packet cannot revive the stale L1 name")
        renamedScan.pairingModelNameFilter = "L2"
        renamedScan.discover(device0344, advertisementData: ["generation": DeviceGeneration.gen1G5K61], rssi: -25)
        check(renamedScan.discoveredPairingDevices.map(\.displayName) == ["L2 0344"],
              "The same UUID is listed only by the current model and real broadcast name")
        check(renamedScan.pairWithDiscoveredDevice(id: device0344.identifier),
              "Matching L2 can still pair despite the old OS name")

        let renamedAfterListing = PairingNameScanProbe()
        renamedAfterListing.pairingModelNameFilter = "L1"
        renamedAfterListing.discover(device0344, advertisementData: ["generation": DeviceGeneration.gen1G5K61,
                                     CBAdvertisementDataLocalNameKey: "L1 0344"], rssi: -35)
        check(renamedAfterListing.discoveredPairingDevices.count == 1, "Initial current L1 advertisement is visible")
        renamedAfterListing.discover(device0344, advertisementData: ["generation": DeviceGeneration.gen1G5K61,
                                     CBAdvertisementDataLocalNameKey: "L2 0344"], rssi: -40)
        check(renamedAfterListing.discoveredPairingDevices.isEmpty &&
              renamedAfterListing.discoveredPeripherals[device0344.identifier] == nil,
              "Changing the current name to L2 immediately revokes the existing L1 row and selection handle")
        check(!renamedAfterListing.pairWithDiscoveredDevice(id: device0344.identifier) &&
              renamedAfterListing.connectedIDs.isEmpty && renamedAfterListing.stoppedProbes == 0,
              "A Pair tap from the obsolete L1 row cannot connect or stop scanning")
        renamedAfterListing.addVerifiedPairingDevice(device0344, displayName: "L1 0344", rssi: -30)
        check(renamedAfterListing.discoveredPairingDevices.isEmpty,
              "A delayed GATT registration cannot restore a row using its captured old name")
        renamedAfterListing.discover(device0344, advertisementData: ["generation": DeviceGeneration.gen1G5K61,
                                     CBAdvertisementDataLocalNameKey: "  "], rssi: -30)
        check(renamedAfterListing.discoveredPairingDevices.isEmpty,
              "Blank name packets also retain the last real L2 name")

        let pendingRename = PairingNameScanProbe()
        pendingRename.pairingModelNameFilter = "L1"
        pendingRename.discover(device0344, advertisementData: [CBAdvertisementDataLocalNameKey: "L1 0344"], rssi: -30)
        check(pendingRename.queued == [device0344.identifier], "Unverified matching L1 enters the service probe queue")
        pendingRename.probedIDs.insert(device0344.identifier)
        pendingRename.discover(device0344, advertisementData: [CBAdvertisementDataLocalNameKey: "L2 0344"], rssi: -30)
        check(pendingRename.queued.isEmpty && !pendingRename.probedIDs.contains(device0344.identifier),
              "A renamed candidate is removed from the pending probes and stale verified IDs")

        let currentOnly = PairingNameScanProbe()
        currentOnly.discover(device0344, advertisementData: ["generation": DeviceGeneration.gen1G5K61,
                             CBAdvertisementDataLocalNameKey: "L2 0344"], rssi: -30)
        currentOnly.discover(device0344, advertisementData: ["generation": DeviceGeneration.gen1G5K61], rssi: -40)
        check(currentOnly.discoveredPairingDevices.map(\.displayName) == ["L2 0344"],
              "Nameless repeat packets preserve the verified L2 row instead of replacing it with cached L1")
        currentOnly.addVerifiedPairingDevice(device0344, displayName: "L1 0344", rssi: -30)
        check(currentOnly.discoveredPairingDevices.map(\.displayName) == ["L2 0344"],
              "Registration always displays the actual current name, even when given a stale label")
        currentOnly.pairingAdvertisedNames.removeAll()
        check(!currentOnly.pairWithDiscoveredDevice(id: device0344.identifier),
              "An old row cannot pair after the search's current-name evidence is cleared")
        check(currentOnly.resolvedName(for: device0344, advertisementData: [:]).isEmpty,
              "Manual pairing never resolves a missing name from the CoreBluetooth cache")
        currentOnly.isManualPairingScan = false
        check(currentOnly.resolvedName(for: device0344, advertisementData: [:]) == "L1 0344",
              "Background and bound reconnect name resolution retains its prior fallback behavior")

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
        check(PairingScanDiscoveryPolicy.acceptsAdvertisement(scanning: true, hasStartedConnect: false,
              pairingActive: true, manualPairing: true, probing: false, userConnecting: false),
              "An ordinary manual scan still accepts advertisements")
        check(PairingScanDiscoveryPolicy.acceptsAdvertisement(scanning: false, hasStartedConnect: true,
              pairingActive: true, manualPairing: true, probing: true, userConnecting: false),
              "Verifying one glasses must not discard other manual-search advertisements")
        check(!PairingScanDiscoveryPolicy.acceptsAdvertisement(scanning: false, hasStartedConnect: true,
              pairingActive: true, manualPairing: true, probing: true, userConnecting: true),
              "An explicit Pair selection closes background discovery admission")
        check(!PairingScanDiscoveryPolicy.acceptsAdvertisement(scanning: false, hasStartedConnect: true,
              pairingActive: true, manualPairing: false, probing: true, userConnecting: false),
              "Bound/background reconnect discovery retains its original gates")
        check(!PairingScanDiscoveryPolicy.acceptsAdvertisement(scanning: false, hasStartedConnect: true,
              pairingActive: false, manualPairing: true, probing: true, userConnecting: false),
              "A cancelled pairing session cannot keep receiving discovery callbacks")
        check(!PairingScanDiscoveryPolicy.acceptsAdvertisement(scanning: false, hasStartedConnect: true,
              pairingActive: true, manualPairing: true, probing: false, userConnecting: false),
              "Ordinary active connections do not open the probe-only discovery exception")

        print("Pairing device names: \(assertions) assertions passed")
    }
}
