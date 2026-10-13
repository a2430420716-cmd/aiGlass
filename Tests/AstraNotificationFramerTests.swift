import Foundation

// Compile the production protocol unchanged; provide only app-wide UI
// localization for this command-line test host.
enum L10n {
    static func t(_ chinese: String, _ english: String) -> String { chinese }
}

@main
enum AstraNotificationFramerTests {
    private static var assertionCount = 0

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        precondition(condition(), message, file: file, line: line)
        assertionCount += 1
    }

    private static func packet(_ command: String, _ payload: [UInt8] = []) -> Data {
        var bytes = Array(command.utf8.prefix(10))
        bytes += Array(repeating: 0, count: 10 - bytes.count)
        bytes += [UInt8(payload.count & 255), UInt8(payload.count >> 8)]
        bytes += payload
        return Data(bytes)
    }

    private static func declared(_ frame: Data, length: Int) -> Data {
        var frame = frame
        frame[10] = UInt8(length & 255)
        frame[11] = UInt8(length >> 8)
        return frame
    }

    static func main() {
        testCompleteConcatenation()
        testTruncationAndFullReadAreIndependent()
        testLegacyFallback()
        testLegacyCloseWifiAcknowledgement()
        testLegacyCloseWifiRejectsMalformedFrames()
        testOtaCancelWireBytes()
        testInvalidHeadersAndLengths()
        testBinaryPayloadAndNoCrossSessionState()
        print("Astra notification framing: \(assertionCount) assertions passed")
    }

    private static func testCompleteConcatenation() {
        let wakeup = packet("wakeuprsp0", [0, 1])
        let translation = packet("trslatests", [1])
        let audio = packet("trslatedat", [3, 0xAA, 0xBB, 0xCC])
        let turn = packet("aivoicetur", [8])
        let frames = [wakeup, translation, audio, turn]
        check(AstraNotificationFramer.frames(in: frames.reduce(Data(), +)) == frames, "Every response in a notification must be delivered in wire order")
        for frame in frames {
            check(AstraNotificationFramer.frames(in: frame) == [frame], "Individual complete response stays byte-identical")
        }
        let empty = packet("transferok")
        check(AstraNotificationFramer.frames(in: empty + wakeup) == [empty, wakeup], "Zero-length frames do not consume the next response")
        let future = packet("futurecmd0", [1, 2, 3])
        check(AstraNotificationFramer.frames(in: future + wakeup) == [future, wakeup], "Valid future commands can be split without adding an allowlist entry")
        var padded = packet("closewifi", [1])
        padded[9] = 32
        check(AstraNotificationFramer.frames(in: padded + wakeup) == [padded, wakeup], "Space-padded headers remain compatible")
        let payload = [UInt8](repeating: 0xA5, count: 300)
        let image = packet("imgrecdata", payload)
        check(AstraNotificationFramer.frames(in: image + wakeup) == [image, wakeup], "Payload length is little endian, including values larger than 255")
    }

    private static func testTruncationAndFullReadAreIndependent() {
        let wakeup = packet("wakeuprsp0", [0, 1])
        for command in ["getdevinfo", "wificonfig", "getworkpat", "getalgoinf"] {
            let full = packet(command, Array(repeating: UInt8(0x31), count: 80))
            let truncated = Data(full.prefix(20))
            check(AstraNotificationFramer.frames(in: truncated) == [truncated], "Truncated \(command) must reach its existing read fallback immediately")
            check(AstraNotificationFramer.frames(in: full) == [full], "The read response is independent, never appended to a buffered notification")
            check(AstraNotificationFramer.frames(in: wakeup + truncated) == [wakeup, truncated], "A valid response preceding a truncated read candidate is preserved")
            check(AstraNotificationFramer.frames(in: truncated + wakeup) == [truncated, wakeup], "A truncated response cannot hide a later complete control response")
            let truncated24 = Data(full.prefix(24))
            check(AstraNotificationFramer.frames(in: truncated24) == [truncated24], "A 24-byte truncated text response is not blindly split into legacy 12-byte blocks")
        }
        let audio = packet("aivoicedat", [3, 1, 2, 3, 3, 4, 5, 6])
        let partial = Data(audio.prefix(17))
        check(AstraNotificationFramer.frames(in: partial) == [partial], "Existing partial audio handling receives the unchanged notification tail")
        check(AstraNotificationFramer.frames(in: Data(audio.suffix(3))).isEmpty, "An isolated continuation is not treated as a fresh command")
    }

    private static func testLegacyFallback() {
        let first = declared(packet("devstatus0"), length: 65)
        let second = declared(packet("batteryntf"), length: 65)
        check(AstraNotificationFramer.frames(in: first + second) == [first, second], "Android's aligned 12-byte legacy response fallback remains available")
        check(AstraNotificationFramer.frames(in: first) == [first], "A single 12-byte legacy notification is passed through")
        let wakeup = packet("wakeuprsp0", [0, 1])
        check(AstraNotificationFramer.frames(in: wakeup + first + second) == [wakeup, first, second], "Legacy fallback also works after standard frames")
        var status = packet("devstatus0", [3])
        status[10] = 0
        check(AstraNotificationFramer.frames(in: status + wakeup) == [status, wakeup], "Existing devstatus0 zero-length firmware workaround keeps the status byte")
        let actualEmpty = packet("devstatus0")
        check(AstraNotificationFramer.frames(in: actualEmpty + wakeup) == [actualEmpty, wakeup], "A genuinely empty status frame does not eat the next command")
    }

    private static func testLegacyCloseWifiAcknowledgement() {
        // Exact RAW callback from the September 22 OTA failure, including its
        // nine-byte command header instead of the normal ten-byte padded header.
        let rawSuccess = Data([0x63, 0x6C, 0x6F, 0x73, 0x65, 0x77, 0x69, 0x66, 0x69, 0x01, 0x00, 0x01])
        let wakeup = packet("wakeuprsp0", [0, 1])
        let translation = packet("trslatests", [1])
        let incomplete = declared(packet("getdevinfo", [0x61, 0x62]), length: 100)

        for status: UInt8 in [0, 1] {
            var raw = rawSuccess
            raw[11] = status
            let normalized = packet("closewifi", [status])
            let framed = AstraNotificationFramer.frames(in: raw)
            check(framed == [normalized], "Short closewifi status \(status) normalizes to the standard header")
            check(framed.count == 1 && AstraA1BleProtocol.parseStatusResponse(framed[0]) == (status == 1), "The existing status parser receives the actual close success or failure")
            check(AstraA1BleProtocol.parseCommandHeader(from: normalized) == "closewifi", "Normalized ACK reaches the existing closewifi command handler")
            check(AstraNotificationFramer.frames(in: raw + wakeup) == [normalized, wakeup], "Short ACK does not consume the next standard frame")
            check(AstraNotificationFramer.frames(in: wakeup + raw) == [wakeup, normalized], "Short ACK after a standard frame is recognized")
            check(AstraNotificationFramer.frames(in: wakeup + raw + translation) == [wakeup, normalized, translation], "Short ACK inside a multi-frame notification preserves frame order")
            check(AstraNotificationFramer.frames(in: raw + raw) == [normalized, normalized], "Consecutive short close ACKs remain separate")
            check(AstraNotificationFramer.frames(in: incomplete + raw) == [incomplete, normalized], "An incomplete earlier frame cannot hide a complete short close ACK")
            check(AstraNotificationFramer.frames(in: Data([0xFF, 0xFE]) + raw) == [normalized], "Malformed prefix can resynchronize to the short close ACK")
            check(AstraNotificationFramer.frames(in: (Data([0xFF]) + raw).dropFirst()) == [normalized], "Short ACK accepts a nonzero Data start index")

            for command in ["closewifi", "closewifi0"] {
                let standard = packet(command, [status])
                check(AstraNotificationFramer.frames(in: standard) == [standard], "Standard \(command) ACK stays byte-identical")
                check(AstraA1BleProtocol.parseStatusResponse(standard) == (status == 1), "Standard \(command) status parsing is preserved")
                check(AstraNotificationFramer.frames(in: standard + raw) == [standard, normalized], "Standard and short ACKs can share a notification")
            }
            var spacePadded = normalized
            spacePadded[9] = 32
            check(AstraNotificationFramer.frames(in: spacePadded + raw) == [spacePadded, normalized], "Space-padded closewifi remains a standard frame")
            let binary = packet("imgrecdata", [0xFE] + Array(raw) + [0xFF])
            check(AstraNotificationFramer.frames(in: binary + raw) == [binary, normalized], "Short ACK bytes inside complete binary payload are never split or normalized")
        }
    }

    private static func testLegacyCloseWifiRejectsMalformedFrames() {
        let raw = Data("closewifi".utf8) + Data([1, 0, 1])
        let wakeup = packet("wakeuprsp0", [0, 1])
        for count in 1..<12 {
            let truncated = Data(raw.prefix(count))
            check(AstraNotificationFramer.frames(in: truncated).isEmpty, "Truncated short close ACK must not complete a waiter")
            let recovered = AstraNotificationFramer.frames(in: truncated + wakeup)
            check(!recovered.contains(packet("closewifi", [1])) && !recovered.contains(packet("closewifi", [0])), "Truncated short close ACK at \(count) bytes must never produce a fabricated status")
            if count >= 10 {
                check(recovered == [wakeup], "Incomplete short close length/status cannot hide the next valid frame")
            }
        }
        for suffix: [UInt8] in [[2, 0, 1], [1, 1, 1], [1, 0, 2], [1, 0, 255]] {
            let invalid = Data("closewifi".utf8) + Data(suffix)
            check(AstraNotificationFramer.frames(in: invalid).isEmpty, "Unsupported short close length or status must not normalize")
            check(AstraNotificationFramer.frames(in: invalid + wakeup) == [wakeup], "Invalid short close ACK must not hide a later response")
        }
        let otherShortCommand = Data("getdevinf".utf8) + Data([1, 0, 1])
        check(AstraNotificationFramer.frames(in: otherShortCommand).isEmpty, "The header exception applies only to closewifi")
    }

    private static func testOtaCancelWireBytes() {
        let expected = Data([0x6F, 0x74, 0x61, 0x63, 0x61, 0x6E, 0x63, 0x65, 0x6C, 0x30, 0x00, 0x00])
        let actual = AstraA1BleProtocol.buildOtaCancelCommand()
        check(actual == expected, "otacancel0 exactly matches Android's ten-byte command plus zero LE16 payload length")
        check(actual.count == 12 && AstraA1BleProtocol.declaredPayloadLength(actual) == 0, "OTA cancel carries no payload")
    }

    private static func testInvalidHeadersAndLengths() {
        let wakeup = packet("wakeuprsp0", [0, 1])
        check(AstraNotificationFramer.frames(in: Data()).isEmpty, "Empty notification produces no frames")
        for count in 1..<12 {
            check(AstraNotificationFramer.frames(in: Data(wakeup.prefix(count))).isEmpty, "An incomplete header is not delivered as a complete frame")
        }
        for bad in [Data(repeating: 0xFF, count: 12), Data(repeating: 0, count: 12), packet("12invalid0"), packet("bad!frame0")] {
            check(AstraNotificationFramer.frames(in: bad).isEmpty, "Malformed command header is discarded")
            check(AstraNotificationFramer.frames(in: bad + wakeup) == [wakeup], "Malformed prefix cannot hide a later known response")
        }
        let oversized = declared(packet("aivoicedat"), length: 65_535)
        check(AstraNotificationFramer.frames(in: oversized) == [oversized], "An incomplete maximum-length header remains available to the existing command handler")
        check(AstraNotificationFramer.frames(in: oversized + wakeup) == [oversized, wakeup], "Bad length cannot consume a later valid frame")
        let short = declared(packet("aivoicedat", [2, 0xAA]), length: 500)
        check(AstraNotificationFramer.frames(in: short + wakeup) == [short, wakeup], "Incomplete payload length resynchronizes at a known complete frame")
        let maximum = packet("imgrecdata", Array(repeating: 0xAB, count: AstraNotificationFramer.maximumPayloadLength))
        check(AstraNotificationFramer.frames(in: maximum) == [maximum], "Largest supported payload remains accepted")
    }

    private static func testBinaryPayloadAndNoCrossSessionState() {
        let nested = packet("wakeuprsp0", [0, 1])
        let outer = packet("imgrecdata", [0, 1] + Array(nested) + [0xFF, 0xEE])
        let next = packet("trslatests", [0])
        check(AstraNotificationFramer.frames(in: outer + next) == [outer, next], "Known command bytes inside a complete binary payload are never split")
        _ = AstraNotificationFramer.frames(in: Data(outer.prefix(13)))
        check(AstraNotificationFramer.frames(in: next) == [next], "Incomplete prior session cannot contaminate a new connection")
        let sliced = (Data([0xFF, 0xFF]) + next).dropFirst(2)
        check(AstraNotificationFramer.frames(in: sliced) == [next], "Data with a nonzero startIndex is accepted safely")
    }
}
