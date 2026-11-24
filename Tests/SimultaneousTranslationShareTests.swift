import Foundation

@main
struct SimultaneousTranslationShareTests {
    @MainActor static func main() {
        func record(_ id: String, source: String, target: String) -> SimultaneousTranslationRecord {
            SimultaneousTranslationRecord(
                id: id, title: "Record \(id)", sourceLanguage: "zh", targetLanguage: "en",
                sourceText: source, targetText: target, createdAt: 0, durationMs: 1_000
            )
        }
        let records = [record("new", source: "你好\n第二行🙂", target: "Hello\nSecond line🙂"),
                       record("old", source: "早上好", target: "Good morning")]
        let utc = TimeZone(secondsFromGMT: 0)!
        let display: (String) -> String = { $0 == "zh" ? "中文" : "English" }
        let empty = SimultaneousTranslationShareFormatter.text(records: records, selectedIDs: [], timeZone: utc, displayLanguage: display)
        precondition(empty.isEmpty, "Empty selection must not share all records")
        let stale = SimultaneousTranslationShareFormatter.text(records: records, selectedIDs: ["missing"], timeZone: utc, displayLanguage: display)
        precondition(stale.isEmpty, "Stale selection must not share unrelated records")
        let one = SimultaneousTranslationShareFormatter.text(records: records, selectedIDs: ["old"], timeZone: utc, displayLanguage: display)
        precondition(one == "Record old\n中文 -> English\n早上好\nGood morning\n1970/01/01 00:00", "Selected record includes both texts, languages and date")
        let both = SimultaneousTranslationShareFormatter.text(records: records, selectedIDs: ["old", "new"], timeZone: utc, displayLanguage: display)
        let expectedFirst = "Record new\n中文 -> English\n你好\n第二行🙂\nHello\nSecond line🙂\n1970/01/01 00:00"
        precondition(both == expectedFirst + "\n\n" + one, "Share keeps visible record order, Unicode and embedded newlines")
        precondition(records[0].sourceText == "你好\n第二行🙂", "Formatting must not mutate stored records")
        print("Simultaneous translation sharing: 5 assertions passed")
    }
}
