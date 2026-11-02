import Foundation

/// Standalone checks against Android BleForegroundService command mappings.
/// swiftc AIGlass/Bluetooth/Gen1/Gen1Protocol.swift \
///   AIGlass/Bluetooth/Gen1/Gen1CommandAdapter.swift Tests/Gen1CommandAdapterTests.swift -o /tmp/gen1-adapter-tests
@main
struct Gen1CommandAdapterTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func packet(_ name: String, _ payload: [UInt8] = []) -> Data {
        var header = Array(name.utf8)
        precondition(header.count <= 10)
        header += Array(repeating: 0, count: 10 - header.count)
        return Data(header + [UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)] + payload)
    }

    static func mapped(_ name: String, _ payload: [UInt8], _ code: UInt8, _ expected: [UInt8]) {
        expect(
            Gen1CommandAdapter.translate(packet(name, payload)) == .init(code: code, payload: Data(expected)),
            "Incorrect Android Gen1 mapping for \(name)"
        )
    }

    static func main() throws {
        // Device metadata keys are the established CYT type0 payload, not model-name hints.
        for (type, command): (UInt8, UInt8) in [(1, 0x63), (2, 0x64), (3, 0x36), (4, 0x45), (5, 0x14), (6, 0x15), (7, 0x05)] {
            mapped("getdevinfo", Array("type0".utf8) + [1, 0, type], command, [])
        }
        mapped("hasnewfile", [], 0x33, [0, 0])
        mapped("getdevstat", [], 0x72, [])
        mapped("takephoto0", [], 0x60, [])
        mapped("startvideo", [], 0x61, [])
        mapped("stopvideo0", [], 0x62, [])
        mapped("factreset0", [], 0x08, [])
        mapped("getweardet", [], 0x85, [])
        mapped("geteqmode0", [], 0x83, [])
        mapped("imgreccap0", [3], 0x70, [])
        mapped("closewifi", [], 0x38, [])

        for enabled: UInt8 in [0, 1] {
            mapped("setweardet", [enabled], 0x84, [enabled])
            mapped("airecord00", [enabled], 0x37, [enabled])
            mapped("trslate000", [enabled], 0x90, [enabled])
            mapped("aivoice000", [enabled], 0x01, [enabled])
            mapped("guidectrl0", [enabled], 0x81, [enabled, 0])
        }
        mapped("aivoice000", [1, 1], 0x01, [1])
        for mode: UInt8 in [0, 1, 2] { mapped("seteqmode0", [mode], 0x82, [mode]) }
        for level: UInt8 in [0, 1, 2, 3] { mapped("imgrecset0", [level], 0x71, [level]) }

        for (index, seconds) in [15, 60, 180, 300, 600].enumerated() {
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: seconds >> ($0 * 8)) }
            mapped("recordtime", bytes, 0x25, [UInt8(index)])
        }
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let sync = Gen1CommandAdapter.translate(packet("synctime00", [0, 0, 0, 0]), now: time)
        expect(sync?.code == 0x04, "Time sync command")
        expect(sync?.payload == Data("1800000000".utf8), "Gen1 uses ASCII Unix seconds, without Gen2 timezone adjustment")

        // Unsupported Gen2 operations must never be sent verbatim to AE3B.
        for name in ["toopenwifi", "getworkpat", "transferok", "deletefile", "otaupload0", "otaupload1", "getalgoinf", "setvidres0", "getvidres0", "setaivsil0", "getaivsil0", "setwakeup0", "getwakeup0", "imgreccan0", "aivlisten0", "wificonfig"] {
            expect(Gen1CommandAdapter.translate(packet(name)) == nil, "Rejected Gen2-only command: \(name)")
        }
        for (name, bytes) in [
            ("recordtime", [UInt8(30), 0, 0, 0]), ("recordtime", [UInt8(60)]),
            ("seteqmode0", [UInt8(3)]), ("seteqmode0", []),
            ("setweardet", [UInt8(2)]), ("airecord00", [UInt8(1), 0]),
            ("trslate000", [UInt8(2)]), ("imgrecset0", [UInt8(4)]),
            ("guidectrl0", [UInt8(9)]), ("aivoice000", [UInt8(2)]),
            ("getdevinfo", Array("type0".utf8) + [1, 0, 8])
        ] {
            expect(Gen1CommandAdapter.translate(packet(name, bytes)) == nil, "Rejected invalid \(name) payload")
        }
        let complete = packet("trslate000", [1])
        for length in 0..<complete.count {
            expect(Gen1CommandAdapter.translate(Data(complete.prefix(length))) == nil, "Reject truncated frame \(length)")
        }
        expect(Gen1CommandAdapter.translate(complete + Data([0])) == nil, "Reject trailing data")
        var oversized = complete
        oversized[11] = 0xFF
        expect(Gen1CommandAdapter.translate(oversized) == nil, "Reject declared length overflow")
        let sliced = Data([0xFF]) + complete
        expect(Gen1CommandAdapter.translate(sliced.dropFirst())?.code == 0x90, "Handle nonzero Data startIndex")
        print("Gen1 command adapter: \(checks) assertions passed")
    }
}
