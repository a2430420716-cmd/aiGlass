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
            case .normal: return L10n.t("标准", "Standard")
            case .detail: return L10n.t("精细", "Detailed")
            case .hd: return L10n.t("极致", "Ultra")
            }
        }

        @MainActor
        var subtitle: String {
            switch self {
            case .fast:
                return L10n.t("瞬间秒出结果，适合识别轮廓清晰、简单的图像", "Returns results quickly for simple images with clear outlines.")
            case .normal:
                return L10n.t("兼顾速度与清晰度，适合日常大部分场景", "Balances speed and clarity for most daily scenarios.")
            case .detail:
                return L10n.t("画质更清晰，适合小字体或细节较多的图像", "Clearer image. Suitable for small text or more details.")
            case .hd:
                return L10n.t("最高清的画质和最准确的识别率，耗时较长", "Highest quality and accuracy, but takes longer.")
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
