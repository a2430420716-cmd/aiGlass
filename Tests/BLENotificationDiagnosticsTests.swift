import Foundation

@main
enum BLENotificationDiagnosticsTests {
    private static var assertionCount = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        assertionCount += 1
    }

    private static func format(_ data: Data?, error: String? = nil) -> BLENotificationDiagnostics.Record {
        BLENotificationDiagnostics.format(
            data: data,
            peripheralID: "test-peripheral",
            characteristicID: "test-characteristic",
            context: "notification/read callback",
            error: error
        )
    }

    private static func packet(_ command: String, payload: Data) -> Data {
        var result = Data(command.utf8)
        result.append(contentsOf: repeatElement(0, count: 10 - result.count))
        result.append(contentsOf: [UInt8(payload.count & 255), UInt8(payload.count >> 8)])
        result.append(payload)
        return result
    }

    static func main() {
        testSplitSerialNumber()
        testShortAndErrorCallbacks()
        testPayloadLimits()
        testPerConnectionBudget()
        print("BLE raw notification diagnostics: \(assertionCount) assertions passed")
    }

    private static func testSplitSerialNumber() {
        let serial = Data("G12345678901234".utf8)
        var payload = Data("sn000".utf8)
        payload.append(contentsOf: [15, 0])
        payload.append(serial)
        let full = packet("getdevinfo", payload: payload)
        check(full.count == 34, "The reproduction packet has the same 34-byte SN length as the tester's log")
        let initial = format(Data(full.prefix(20)))
        let continuation = format(Data(full.suffix(14)))
        check(initial.title.contains("RAW") && initial.title.contains("before framing"), "Raw evidence is visibly distinct from parsed packets")
        check(initial.detail.contains("rawBytes=20"), "Initial truncated packet keeps its physical callback length")
        check(continuation.detail.contains("rawBytes=14"), "Headerless continuation remains visible")
        check(continuation.detail.contains("hex=31 32 33 34 35 36 37 38 39 30 31 32 33 34"), "All continuation bytes survive without command-header filtering")
        check(continuation.detail.contains("omittedBytes=0"), "No continuation bytes are silently omitted")
        check(continuation.detail.contains("peripheral=test-peripheral characteristic=test-characteristic"), "Raw bytes retain callback source identity")
    }

    private static func testShortAndErrorCallbacks() {
        for count in 1..<12 {
            let result = format(Data(repeating: 0xE1, count: count))
            check(result.detail.contains("rawBytes=\(count)"), "Short raw callback is recorded even without a protocol header")
            check(result.detail.contains("omittedBytes=0"), "Short callback is not truncated by diagnostics")
        }
        check(format(Data()).detail.contains("hex=<empty>"), "Empty value is distinguishable from absent value")
        check(format(nil).detail.contains("value=nil rawBytes=0"), "Missing value does not masquerade as an empty packet")
        let error = format(Data([0xCA, 0xFE]), error: "ATT request not supported")
        check(error.detail.contains("value=ignored rawBytes=0 cachedValueBytes=2"), "Failed read does not count cached characteristic bytes as received data")
        check(error.detail.contains("error=ATT request not supported"), "ATT error survives export")
        check(!error.detail.contains("CA FE") && !error.detail.contains("hex="), "Cached bytes on an error never masquerade as current wire bytes")
        check(format(nil, error: "Disconnected").detail.contains("error=Disconnected"), "No-value error callbacks remain diagnosable")
    }

    private static func testPayloadLimits() {
        let large = format(Data(repeating: 0xA7, count: 65_535))
        check(large.detail.contains("rawBytes=65535"), "Large callback retains its true original byte count")
        check(large.detail.contains("omittedBytes=65471"), "Hex preview explicitly accounts for every byte beyond its 64-byte cap")
        let hex = large.detail.components(separatedBy: "\n").first { $0.hasPrefix("hex=") }!
        check(hex.dropFirst(4).split(separator: " ").count == 64, "Large callback never expands more than 64 hex bytes")
        for command in ["aivoicedat", "trslatedat", "imgrecdata"] {
            let media = packet(command, payload: Data(repeating: 0xA7, count: 1024))
            let redacted = format(media)
            check(redacted.detail.contains("media=\(command) payload=omitted"), "Recognized media payload is omitted")
            check(!redacted.detail.contains("hex="), "Media cannot leak through a hex preview")
            check(redacted.detail.contains("omittedBytes=1036"), "Media omission preserves raw length evidence")
            let concatenated = format(packet("devstatus0", payload: Data([0])) + media)
            check(!concatenated.detail.contains("hex="), "Media appended to a control frame remains redacted")
        }
    }

    private static func testPerConnectionBudget() {
        var budget = BLERawDiagnosticBudget()
        let accepted = (0..<256).allSatisfy { _ in budget.record() == .record }
        check(accepted, "Each connection keeps its first 256 raw callbacks")
        check(budget.record() == .limitReached, "The first omitted callback emits one explicit limit event")
        check((0..<1000).allSatisfy { _ in budget.record() == .suppress }, "Further traffic cannot flood logs with limit events")
        budget.reset()
        check(budget.record() == .record, "A new connection restores its diagnostic budget")
        var disabled = BLERawDiagnosticBudget(limit: 0)
        check(disabled.record() == .limitReached && disabled.record() == .suppress, "A zero budget still reports its omission once")
    }
}
