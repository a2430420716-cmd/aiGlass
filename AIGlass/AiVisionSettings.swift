import Foundation

/// 智能图像识别质量档位（本地持久化，每次 imgreccap0 携带）。
enum AiVisionSettings {
    static let prefsKey = "ai_vision_level"
    static let defaultLevel: UInt8 = 1

    enum Level: UInt8, CaseIterable, Identifiable {
        case fast = 0
        case normal = 1
        case detail = 2
        case hd = 3

        var id: UInt8 { rawValue }

        @MainActor
        var title: String {
            switch self {
            case .fast: return L10n.t("极速", "Fast")
            case .normal: return L10n.t("普通", "Standard")
            case .detail: return L10n.t("细节", "Detailed")
            case .hd: return L10n.t("高清", "Ultra")
            }
        }
    }

    static var level: UInt8 {
        get {
            let raw = UserDefaults.standard.object(forKey: prefsKey) as? Int
            let value = UInt8(raw ?? Int(defaultLevel))
            return AstraA1BleProtocol.normalizeAIVisionLevel(value)
        }
        set {
            UserDefaults.standard.set(
                Int(AstraA1BleProtocol.normalizeAIVisionLevel(newValue)),
                forKey: prefsKey
            )
        }
    }

    @MainActor
    static var levelTitle: String {
        Level(rawValue: level)?.title ?? Level.normal.title
    }
}
