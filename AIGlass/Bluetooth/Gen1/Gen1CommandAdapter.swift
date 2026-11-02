import Foundation

/// Maps the shared application commands to the G5K61 wire protocol. Unsupported
/// second-generation commands must never reach a first-generation peripheral.
enum Gen1CommandAdapter {
    struct Command: Equatable {
        let code: UInt8
        var payload = Data()
    }

    static func translate(_ packet: Data, now: Date = Date()) -> Command? {
        let bytes = Array(packet)
        guard bytes.count >= 12 else { return nil }
        let length = Int(bytes[10]) | Int(bytes[11]) << 8
        guard bytes.count == 12 + length else { return nil }
        let header = String(bytes: bytes.prefix(10).prefix { $0 != 0 }, encoding: .utf8) ?? ""
        let payload = Data(bytes.dropFirst(12))
        switch header {
        case "getdevinfo":
            guard payload.count == 8, payload.prefix(5) == Data("type0".utf8),
                  payload[5] == 1, payload[6] == 0 else { return nil }
            let commands: [UInt8: UInt8] = [1: 0x63, 2: 0x64, 3: 0x36, 4: 0x45, 5: 0x14, 6: 0x15, 7: 0x05]
            return commands[payload[7]].map { Command(code: $0) }
        case "hasnewfile": return Command(code: Gen1Commands.fileList, payload: Gen1Payloads.fileListQuery())
        case "getdevstat": return Command(code: 0x72)
        case "takephoto0": return Command(code: 0x60)
        case "startvideo": return Command(code: 0x61)
        case "stopvideo0": return Command(code: 0x62)
        case "factreset0": return Command(code: 0x08)
        case "recordtime":
            guard payload.count == 4 else { return nil }
            let seconds = payload.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            guard let index = [15, 60, 180, 300, 600].firstIndex(of: Int(seconds)) else { return nil }
            return Command(code: 0x25, payload: Data([UInt8(index)]))
        case "setweardet": return booleanCommand(0x84, payload)
        case "getweardet": return Command(code: 0x85)
        case "seteqmode0":
            guard payload.count == 1, payload[0] <= 2 else { return nil }
            return Command(code: 0x82, payload: payload)
        case "geteqmode0": return Command(code: 0x83)
        case "imgrecset0":
            guard payload.count == 1, payload[0] <= 3 else { return nil }
            return Command(code: 0x71, payload: payload)
        case "imgreccap0": return Command(code: 0x70)
        case "aivoice000":
            guard let enabled = payload.first, enabled <= 1 else { return nil }
            return Command(code: 0x01, payload: Data([enabled]))
        case "airecord00": return booleanCommand(0x37, payload)
        case "trslate000": return booleanCommand(0x90, payload)
        case "guidectrl0":
            guard payload.count == 1, payload[0] <= 1 else { return nil }
            return Command(code: 0x81, payload: Data([payload[0], 0]))
        case "synctime00":
            // G5K61 expects ASCII Unix time, without the Gen2 timezone adjustment.
            return Command(code: 0x04, payload: Gen1Payloads.syncTime(epochSeconds: Int64(now.timeIntervalSince1970)))
        case "closewifi", "closewifi0": return Command(code: 0x38)
        default: return nil
        }
    }

    private static func booleanCommand(_ code: UInt8, _ payload: Data) -> Command? {
        guard payload.count == 1, payload[0] <= 1 else { return nil }
        return Command(code: code, payload: payload)
    }
}
