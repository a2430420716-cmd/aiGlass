import Foundation

/// Exercise the production catalog in both display languages without loading UI.
@MainActor enum L10n {
    static var usesEnglish = false
    static func t(_ chinese: String, _ english: String) -> String {
        usesEnglish ? english : chinese
    }
}

@main struct TranslationLanguageTests {
    struct AndroidLanguage: Decodable {
        let chinese: String
        let english: String
        let code: String
    }

    @MainActor static func main() throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let expected = try JSONDecoder().decode([AndroidLanguage].self, from: fixture)
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        check(expected.count == 60, "The supplied Android catalog has 60 selectable languages")
        check(TranslationLanguage.selectableCases.count == expected.count, "All Android choices are exposed")
        check(Set(expected.map(\.code)).count == expected.count, "Android request codes are unique")
        check(Set(TranslationLanguage.selectableCases.map(\.code)).count == expected.count, "iOS request codes are unique")
        for (language, android) in zip(TranslationLanguage.selectableCases, expected) {
            check(language.rawValue == android.chinese, "Chinese labels and ordering match Android")
            check(language.englishName == android.english, "English labels and ordering match Android")
            check(language.code == android.code, "Backend codes match Android")
            for value in [android.chinese, android.english, android.english.lowercased(), android.code, android.code.uppercased()] {
                check(TranslationLanguage.fromDisplayName(value) == language, "Selection/history resolves the same language: \(value)")
                check(TranslationLanguage.code(forDisplayName: " \n\(value)\t") == android.code, "Whitespace cannot change a request language")
            }
        }
        for english in [false, true] {
            L10n.usesEnglish = english
            check(TranslationLanguage.displayNames == expected.map { english ? $0.english : $0.chinese },
                  "The complete localized picker order matches Android")
            check(TranslationLanguage.defaultEnglishDisplayName == (english ? "English" : "英文"),
                  "The existing default header label remains compatible")
            for label in TranslationLanguage.displayNames {
                let fallback = TranslationLanguage.fallback(excluding: label)
                check(TranslationLanguage.code(forDisplayName: fallback) != TranslationLanguage.code(forDisplayName: label),
                      "Same-language exclusion always yields another supported choice")
            }
        }
        for alias in ["英文", "英语", "English", "en", "EN"] {
            check(TranslationLanguage.code(forDisplayName: alias) == "en", "Existing English aliases stay valid")
        }
        check(TranslationLanguage.code(forDisplayName: "尼泊尔语") == "ne", "Older Chinese Nepali records still decode")
        check(TranslationLanguage.code(forDisplayName: "Nepali") == "ne", "Older English Nepali records still decode")
        check(!TranslationLanguage.selectableCases.contains(.nepali), "Legacy-only choices do not expand the Android catalog")
        check(TranslationLanguage.code(forDisplayName: "unknown language") == "zh", "Unknown values preserve the prior fallback")
        print("Translation language catalog: \(assertions) assertions passed")
    }
}
