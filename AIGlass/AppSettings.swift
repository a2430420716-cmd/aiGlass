import Foundation

enum AppLanguageOption: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese
    case englishUS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.t("跟随手机系统", "Follow System")
        case .simplifiedChinese: "简体中文"
        case .englishUS: "English (US)"
        }
    }

    var aboutDisplayName: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
            if preferred.hasPrefix("en") {
                return "English (US)"
            }
            return "简体中文"
        case .simplifiedChinese:
            return "简体中文"
        case .englishUS:
            return "English (US)"
        }
    }
}

enum DataStorageRegion: String, CaseIterable, Identifiable {
    case usa
    case europeAmerica
    case asiaPacific
    case mainlandChina

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usa: L10n.t("美国", "United States")
        case .europeAmerica: L10n.t("欧美地区", "Europe & Americas")
        case .asiaPacific: L10n.t("亚太地区", "Asia Pacific")
        case .mainlandChina: L10n.t("中国大陆", "Mainland China")
        }
    }
}

extension Notification.Name {
    /// `AppSettings.language` 写入后广播，`AppLanguageManager` 据此刷新内存态。
    static let appLanguageChanged = Notification.Name("AppLanguageChanged")
}

enum AppSettings {
    private static let dataStorageKey = "app.dataStorage"
    private static let imageWatermarkEnabledKey = "app.imageWatermarkEnabled"
    private static let imageWatermarkStyleKey = "app.imageWatermarkStyle"
    private static let videoWatermarkEnabledKey = "app.videoWatermarkEnabled"

    /// Use the same bundle localization as iOS permission dialogs. Legacy
    /// app.language preferences no longer override the system's app language.
    static var language: AppLanguageOption {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .englishUS
    }

    static var dataStorageRegion: DataStorageRegion {
        get {
            guard let raw = UserDefaults.standard.string(forKey: dataStorageKey),
                  let region = DataStorageRegion(rawValue: raw) else {
                return .usa
            }
            return region
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: dataStorageKey)
        }
    }

    /// 眼镜设置：图片水印总开关。
    static var imageWatermarkEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: imageWatermarkEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: imageWatermarkEnabledKey) }
    }

    /// 图片水印样式 1 / 2 / 3，默认样式 2。
    static var imageWatermarkStyle: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: imageWatermarkStyleKey)
            return (1...3).contains(value) ? value : 2
        }
        set {
            let clamped = (1...3).contains(newValue) ? newValue : 2
            UserDefaults.standard.set(clamped, forKey: imageWatermarkStyleKey)
        }
    }

    static var videoWatermarkEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: videoWatermarkEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: videoWatermarkEnabledKey) }
    }
}
