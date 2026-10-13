import Foundation

/// Read-only discovery and safe shutdown must remain available while binding changes.
/// Everything else, including unknown commands, requires an available device card.
enum DeviceCommandAvailabilityPolicy {
    static func sharedCommand(in packet: Data) -> (name: String, payload: Data)? {
        let bytes = Array(packet)
        guard bytes.count >= 12 else { return nil }
        let payloadLength = Int(bytes[10]) | Int(bytes[11]) << 8
        guard bytes.count == 12 + payloadLength,
              let name = String(bytes: bytes.prefix(10).prefix { $0 != 0 }, encoding: .utf8),
              !name.isEmpty else { return nil }
        return (name, Data(bytes.dropFirst(12)))
    }

    static func requiresAvailableDevice(sharedCommand: String, payload: Data) -> Bool {
        switch sharedCommand {
        case "getdevinfo", "hasnewfile", "getdevstat", "geteqmode0", "getvidres0",
             "getweardet", "getaivsil0", "getwakeup0", "getalgoinf", "getworkpat":
            return false
        case "stopvideo0", "closewifi", "closewifi0", "otacancel0", "imgreccan0", "transferok":
            return false
        case "airecord00", "aivoice000", "trslate000", "guidectrl0":
            return payload != Data([0])
        default:
            return true
        }
    }

    static func requiresAvailableDevice(gen1Command: UInt8, payload: Data) -> Bool {
        switch gen1Command {
        case Gen1Commands.battery, Gen1Commands.newFileCount,
             Gen1Commands.bluetoothVersion, Gen1Commands.firmwareVersion,
             Gen1Commands.wifiConfig, Gen1Commands.bleMac, Gen1Commands.wearingState,
             Gen1Commands.networkStatus, Gen1Commands.snAuth, Gen1Commands.storage,
             Gen1Commands.deviceName, Gen1Commands.deviceType, Gen1Commands.systemName,
             Gen1Commands.deviceStatusQuery, Gen1Commands.eqQuery,
             Gen1Commands.wearingQuery, Gen1Commands.recordDurationQuery:
            return !payload.isEmpty
        case Gen1Commands.fileList:
            return !payload.isEmpty && payload != Data([0, 0])
        case Gen1Commands.stopVideo, Gen1Commands.closeHotspot:
            return !payload.isEmpty
        case Gen1Commands.aiVoice, Gen1Commands.aiRecord, Gen1Commands.translateRecord:
            return payload != Data([0])
        case Gen1Commands.tutorial:
            return payload != Data([0, 0])
        case Gen1Commands.aiImage:
            // The final cumulative ACK lets an existing transfer release its send window.
            return payload.count != 3 || payload.first != 0x05
        default:
            return true
        }
    }
}
