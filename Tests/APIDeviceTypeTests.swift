import Foundation

enum L10n {
    nonisolated static var usesEnglish: Bool { true }
    nonisolated static func t(_ zh: String, _ en: String) -> String { en }
}

@main struct APIDeviceTypeTests {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            precondition(value, message)
        }
        func model(_ type: Any? = nil, name: String = "L3") throws -> DeviceModelItem {
            var json: [String: Any] = ["id": 1, "model_name": name, "model_name_alias": "Renamed", "eq_name": "MOCO"]
            if let type { json["device_type"] = type }
            return try JSONDecoder().decode(DeviceModelItem.self, from: JSONSerialization.data(withJSONObject: json))
        }
        func user(_ type: Any? = nil, name: String = "L3", modelName: String = "Astra A1", id: Int = 1) throws -> UserDevice {
            var json: [String: Any] = ["id": id, "device_name": name, "model_name": modelName,
                                       "serial_number": "00000000-0000-0000-0000-00000000000\(id)"]
            if let type { json["device_type"] = type }
            return try JSONDecoder().decode(UserDevice.self, from: JSONSerialization.data(withJSONObject: json))
        }

        for name in ["L2", "L3", "Astra A1", "My glasses", "眼镜新名称"] {
            let first = try user(1, name: name)
            expect(first.deviceType == .firstGeneration, "userinfo decodes first-generation type")
            expect(first.cardImageName == "glass1", "Renaming must not override first-generation metadata")
            expect(first.displayName == name && DeviceCardData(device: first).name == name,
                   "API generation never replaces the corresponding device's display name")
            let second = try model(2, name: name)
            expect(second.deviceType == .secondGeneration && second.glassDeviceModel == .astraA1,
                   "Model list type wins over model and alias names")
            expect(second.modelName == name && second.displayName == "Renamed",
                   "Model list preserves the API model name and display alias")
        }
        let firstString = try model(" 1 ", name: "Astra A1")
        let secondString = try user("2", name: "L1", modelName: "Lumina L1")
        expect(firstString.glassDeviceModel == .luminaL1, "String API type accepted")
        expect(secondString.cardImageName == "glass2", "Conflicting old model name cannot override type 2")
        let invalidValues: [Any] = [0, 3, -1, "invalid", true, 2.5, ["unexpected": 1]]
        for value in invalidValues {
            let item = try model(value, name: "Lumina L1")
            expect(item.deviceType == .unknown && item.glassDeviceModel == .unknown,
                   "Invalid explicit type stays unknown, never a name guess")
            let bound = try user(value, modelName: "Lumina L1")
            expect(bound.deviceType == .unknown, "Invalid type does not fail whole userinfo decoding")
        }
        let oldModel = try model(name: "Lumina L1")
        let nullModel = try model(NSNull(), name: "Lumina L1")
        expect(oldModel.deviceType == nil && oldModel.glassDeviceModel == .luminaL1, "Missing field preserves older response compatibility")
        expect(nullModel.deviceType == nil, "Null optional field remains compatible")

        let first = try user(1, name: "Same name", id: 1)
        let second = try user(2, name: "Same name", modelName: "L1", id: 2)
        let cards = [first, second].map(DeviceCardData.init(device:))
        expect(cards.map(\.deviceType) == [.firstGeneration, .secondGeneration], "Mixed device array retains separate types")
        expect(cards.map(\.imageName) == ["glass1", "glass2"], "Cards use their own type, not shared display names")
        let renamed = first.updatingName("L3")
        expect(renamed.deviceType == .firstGeneration && renamed.serialNumber == first.serialNumber,
               "User-device rename preserves generation and identity")
        expect(renamed.displayName == "L3" && first.displayName == "Same name",
               "A rename changes only its own device's display name")
        let renamedCard = cards[0].withDisplayName("L3")
        let connected = renamedCard.withConnection(isConnected: true, batteryPercent: 50, isCharging: false)
        expect(renamedCard.deviceType == .firstGeneration && connected.deviceType == .firstGeneration,
               "Home card copies preserve API type")
        expect(renamedCard.name == "L3" && connected.name == "L3" && cards[1].name == "Same name",
               "Connection and rename preserve individual card names")

        let pairing = DeviceTypePairingProbe()
        pairing.selectDevice(try model(1), guideItems: [])
        pairing.startPairing()
        expect(pairing.selectedDeviceType == .firstGeneration && pairing.pairingModel == .luminaL1,
               "Selected renamed model retains API generation")
        expect(pairing.astraA1BleManager.requestedType == .firstGeneration,
               "Pairing forwards model-list type to BLE discovery")
        expect(pairing.selectedAPIModelName == "L3",
               "Pairing retains the real API model name instead of substituting a generation label")
        pairing.refreshSelectedDeviceModel(try model())
        expect(pairing.selectedDeviceType == .firstGeneration && pairing.pairingModel == .luminaL1,
               "Detail response missing type cannot erase selected list type")
        pairing.refreshSelectedDeviceModel(try model(2))
        expect(pairing.selectedDeviceType == .secondGeneration && pairing.pairingModel == .astraA1,
               "Explicit fresh detail type updates selection")
        pairing.refreshSelectedDeviceModel(try model(1, name: "different model"))
        expect(pairing.selectedDeviceType == .secondGeneration, "Stale other-model detail cannot change current type")
        expect(APIDeviceType.firstGeneration.matches(.gen1G5K61), "First generation matches its GATT protocol")
        expect(APIDeviceType.secondGeneration.matches(.gen2), "Second generation matches its GATT protocol")
        expect(!APIDeviceType.firstGeneration.matches(.gen2) && !APIDeviceType.secondGeneration.matches(.gen1G5K61),
               "Contradictory GATT protocol is rejected")
        expect(!APIDeviceType.unknown.matches(.gen1G5K61) && !APIDeviceType.firstGeneration.matches(.unknown),
               "Unknown metadata or protocol cannot authorize generation-specific commands")
        print("API device type: \(checks) assertions passed")
    }
}
