import Foundation

enum TranslationLanguage: String, CaseIterable, Identifiable, Hashable {
    case chinese = "中文"
    case russian = "俄语"
    case korean = "韩语"
    case german = "德语"
    case japanese = "日语"
    case vietnamese = "越南语"
    case arabic = "阿拉伯语"
    case nepali = "尼泊尔语"
    case romanian = "罗马尼亚语"
    case hindi = "印地语"
    case french = "法语"
    case english = "英语"

    var id: String { rawValue }

    /// 英文展示名（与 rawValue 中文一一对应）。
    var englishName: String {
        switch self {
        case .chinese: return "Chinese"
        case .russian: return "Russian"
        case .korean: return "Korean"
        case .german: return "German"
        case .japanese: return "Japanese"
        case .vietnamese: return "Vietnamese"
        case .arabic: return "Arabic"
        case .nepali: return "Nepali"
        case .romanian: return "Romanian"
        case .hindi: return "Hindi"
        case .french: return "French"
        case .english: return "English"
        }
    }

    /// 展示名：英文兼容「英文」别名。
    @MainActor
    var displayName: String {
        switch self {
        case .english: return L10n.t("英文", "English")
        default: return L10n.t(rawValue, englishName)
        }
    }

    /// 对齐安卓 `languageCode()`。
    var code: String {
        switch self {
        case .chinese: return "zh"
        case .russian: return "ru"
        case .korean: return "ko"
        case .german: return "de"
        case .japanese: return "ja"
        case .vietnamese: return "vi"
        case .arabic: return "ar"
        case .nepali: return "ne"
        case .romanian: return "ro"
        case .hindi: return "hi"
        case .french: return "fr"
        case .english: return "en"
        }
    }

    /// 列表展示名：对齐安卓 `translation_languages`（英语用「英语」）。
    @MainActor
    static var displayNames: [String] {
        allCases.map { L10n.t($0.rawValue, $0.englishName) }
    }

    /// 默认目标语言展示名（安卓 string `translation_english` = 英文）。
    @MainActor
    static var defaultEnglishDisplayName: String { L10n.t("英文", "English") }

    static func fromDisplayName(_ name: String) -> TranslationLanguage {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "英文" || trimmed == "英语" || trimmed.lowercased().contains("english") {
            return .english
        }
        if let match = allCases.first(where: {
            $0.rawValue == trimmed
                || $0.englishName.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return match
        }
        if trimmed.contains("日") || trimmed.lowercased().contains("japanese") { return .japanese }
        if trimmed.contains("韩") || trimmed.lowercased().contains("korean") { return .korean }
        if trimmed.contains("英") { return .english }
        return .chinese
    }

    static func code(forDisplayName name: String) -> String {
        fromDisplayName(name).code
    }

    @MainActor
    static func fallback(excluding current: String) -> String {
        let excluded = code(forDisplayName: current)
        return allCases.first { $0.code != excluded }.map { L10n.t($0.rawValue, $0.englishName) }
            ?? L10n.t(chinese.rawValue, chinese.englishName)
    }
}
