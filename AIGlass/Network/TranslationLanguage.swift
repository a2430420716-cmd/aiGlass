import Foundation

/// Translation choices follow glasses(3).zip's translation_languages/code arrays.
enum TranslationLanguage: String, CaseIterable, Identifiable, Hashable {
    case chinese = "中文"
    case english = "英语"
    case arabic = "阿拉伯语"
    case german = "德语"
    case french = "法语"
    case spanish = "西班牙语"
    case portuguese = "葡萄牙语"
    case indonesian = "印度尼西亚语"
    case italian = "意大利语"
    case korean = "韩语"
    case russian = "俄语"
    case thai = "泰语"
    case vietnamese = "越南语"
    case japanese = "日语"
    case turkish = "土耳其语"
    case hindi = "印地语"
    case malay = "马来语"
    case dutch = "荷兰语"
    case urdu = "乌尔都语"
    case norwegian = "挪威语"
    case swedish = "瑞典语"
    case danish = "丹麦语"
    case hebrew = "希伯来语"
    case finnish = "芬兰语"
    case polish = "波兰语"
    case icelandic = "冰岛语"
    case czech = "捷克语"
    case filipino = "菲律宾语"
    case persian = "波斯语"
    case cantonese = "粤语"
    case greek = "希腊语"
    case afrikaans = "南非荷兰语"
    case asturian = "阿斯图里亚斯语"
    case belarusian = "白俄罗斯语"
    case bulgarian = "保加利亚语"
    case bengali = "孟加拉语"
    case bosnian = "波斯尼亚语"
    case catalan = "加泰罗尼亚语"
    case cebuano = "宿务语"
    case estonian = "爱沙尼亚语"
    case galician = "加利西亚语"
    case gujarati = "古吉拉特语"
    case croatian = "克罗地亚语"
    case hungarian = "匈牙利语"
    case javanese = "爪哇语"
    case kazakh = "哈萨克语"
    case kannada = "卡纳达语"
    case kyrgyz = "柯尔克孜语"
    case latvian = "拉脱维亚语"
    case macedonian = "马其顿语"
    case malayalam = "马拉雅拉姆语"
    case marathi = "马拉地语"
    case punjabi = "旁遮普语"
    case romanian = "罗马尼亚语"
    case slovak = "斯洛伐克语"
    case slovenian = "斯洛文尼亚语"
    case swahili = "斯瓦希里语"
    case tajik = "塔吉克语"
    case azerbaijani = "阿塞拜疆语"
    case ukrainian = "乌克兰语"

    // Retain decoding/display of records from older builds; Android no longer lists it.
    case nepali = "尼泊尔语"

    var id: String { rawValue }

    /// Same order as Android; legacy-only languages do not appear in new choices.
    static var selectableCases: [TranslationLanguage] {
        allCases.filter { $0 != .nepali }
    }

    var englishName: String { metadata.englishName }
    var code: String { metadata.code }

    private var metadata: (englishName: String, code: String) {
        switch self {
        case .chinese: return ("Chinese", "zh")
        case .english: return ("English", "en")
        case .arabic: return ("Arabic", "ar")
        case .german: return ("German", "de")
        case .french: return ("French", "fr")
        case .spanish: return ("Spanish", "es")
        case .portuguese: return ("Portuguese", "pt")
        case .indonesian: return ("Indonesian", "id")
        case .italian: return ("Italian", "it")
        case .korean: return ("Korean", "ko")
        case .russian: return ("Russian", "ru")
        case .thai: return ("Thai", "th")
        case .vietnamese: return ("Vietnamese", "vi")
        case .japanese: return ("Japanese", "ja")
        case .turkish: return ("Turkish", "tr")
        case .hindi: return ("Hindi", "hi")
        case .malay: return ("Malay", "ms")
        case .dutch: return ("Dutch", "nl")
        case .urdu: return ("Urdu", "ur")
        case .norwegian: return ("Norwegian", "nb")
        case .swedish: return ("Swedish", "sv")
        case .danish: return ("Danish", "da")
        case .hebrew: return ("Hebrew", "he")
        case .finnish: return ("Finnish", "fi")
        case .polish: return ("Polish", "pl")
        case .icelandic: return ("Icelandic", "is")
        case .czech: return ("Czech", "cs")
        case .filipino: return ("Filipino", "fil")
        case .persian: return ("Persian", "fa")
        case .cantonese: return ("Cantonese", "yue")
        case .greek: return ("Greek", "el")
        case .afrikaans: return ("Afrikaans", "af")
        case .asturian: return ("Asturian", "ast")
        case .belarusian: return ("Belarusian", "be")
        case .bulgarian: return ("Bulgarian", "bg")
        case .bengali: return ("Bengali", "bn")
        case .bosnian: return ("Bosnian", "bs")
        case .catalan: return ("Catalan", "ca")
        case .cebuano: return ("Cebuano", "ceb")
        case .estonian: return ("Estonian", "et")
        case .galician: return ("Galician", "gl")
        case .gujarati: return ("Gujarati", "gu")
        case .croatian: return ("Croatian", "hr")
        case .hungarian: return ("Hungarian", "hu")
        case .javanese: return ("Javanese", "jv")
        case .kazakh: return ("Kazakh", "kk")
        case .kannada: return ("Kannada", "kn")
        case .kyrgyz: return ("Kyrgyz", "ky")
        case .latvian: return ("Latvian", "lv")
        case .macedonian: return ("Macedonian", "mk")
        case .malayalam: return ("Malayalam", "ml")
        case .marathi: return ("Marathi", "mr")
        case .punjabi: return ("Punjabi", "pa")
        case .romanian: return ("Romanian", "ro")
        case .slovak: return ("Slovak", "sk")
        case .slovenian: return ("Slovenian", "sl")
        case .swahili: return ("Swahili", "sw")
        case .tajik: return ("Tajik", "tg")
        case .azerbaijani: return ("Azerbaijani", "az")
        case .ukrainian: return ("Ukrainian", "uk")
        case .nepali: return ("Nepali", "ne")
        }
    }

    /// Keep the existing short English label in the translation headers.
    @MainActor
    var displayName: String {
        switch self {
        case .english: return L10n.t("英文", "English")
        default: return L10n.t(rawValue, englishName)
        }
    }

    @MainActor
    static var displayNames: [String] {
        selectableCases.map { L10n.t($0.rawValue, $0.englishName) }
    }

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
                || $0.code.caseInsensitiveCompare(trimmed) == .orderedSame
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
        return selectableCases.first { $0.code != excluded }.map { L10n.t($0.rawValue, $0.englishName) }
            ?? L10n.t(chinese.rawValue, chinese.englishName)
    }
}
