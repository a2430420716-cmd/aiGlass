import Combine
import Foundation
import SwiftUI

/// App 内语言管理：读取 `AppSettings.language`，暴露 `usesEnglish` 与文案切换助手。
/// 切换语言时发 `objectWillChange` + 刷新 `refreshID`，驱动订阅视图重建。
@MainActor
final class AppLanguageManager: ObservableObject {
    static let shared = AppLanguageManager()

    @Published private(set) var option: AppLanguageOption
    /// 绑定到主界面 `.id(...)` 上，语言切换时强制重建 tab / 设置等主界面。
    @Published private(set) var refreshID = UUID()

    private init() {
        option = AppSettings.language
        NotificationCenter.default.addObserver(
            forName: .appLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncFromSettings()
            }
        }
    }

    /// 当前是否使用英文。`system` 跟随手机首选语言。
    var usesEnglish: Bool {
        switch option {
        case .englishUS:
            return true
        case .simplifiedChinese:
            return false
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "zh"
            return preferred.hasPrefix("en")
        }
    }

    var isEnglish: Bool { usesEnglish }

    /// 中英切换文案助手。
    func text(_ zh: String, en: String) -> String {
        usesEnglish ? en : zh
    }

    /// 应用语言设置：保存到 `AppSettings` 并通知订阅者刷新。
    func apply(_ newOption: AppLanguageOption) {
        AppSettings.language = newOption
        guard newOption != option else {
            // 即使值相同（system 下首选语言可能变化）也刷新一次界面。
            refreshID = UUID()
            objectWillChange.send()
            return
        }
        option = newOption
        refreshID = UUID()
        objectWillChange.send()
    }

    /// 供 `AppSettings` 写入后回调同步内存态（外部直接改 AppSettings.language 时使用）。
    func syncFromSettings() {
        let current = AppSettings.language
        if current != option {
            option = current
            refreshID = UUID()
            objectWillChange.send()
        }
    }
}

/// 中英文案切换助手，与 Android 多语言资源对齐。
/// 用法：`L10n.t("中文", "English")`
///
/// 刻意声明为 `nonisolated`：网络层、解码回调、后台 Task 里的用户可见提示同样需要翻译，
/// 直接读 UserDefaults 而不依赖 `AppLanguageManager`（后者是 MainActor 隔离的）。
enum L10n {
    nonisolated static func t(_ zh: String, _ en: String) -> String {
        usesEnglish ? en : zh
    }

    nonisolated static var usesEnglish: Bool {
        let raw = UserDefaults.standard.string(forKey: "app.language") ?? ""
        switch raw {
        case "englishUS":
            return true
        case "system":
            return (Locale.preferredLanguages.first ?? "zh").hasPrefix("en")
        default:
            // 未设置时与 AppSettings.language 默认值保持一致：简体中文。
            return false
        }
    }
}
