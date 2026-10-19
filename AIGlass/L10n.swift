import Combine
import Foundation
import SwiftUI
import UIKit

/// App UI and system permission dialogs share the iOS-selected bundle language.
@MainActor
final class AppLanguageManager: ObservableObject {
    static let shared = AppLanguageManager()

    @Published private(set) var option: AppLanguageOption
    /// 绑定到主界面 `.id(...)` 上，语言切换时强制重建 tab / 设置等主界面。
    @Published private(set) var refreshID = UUID()

    private init() {
        option = AppSettings.language
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncFromSettings()
            }
        }
    }

    var usesEnglish: Bool { L10n.usesEnglish }

    var isEnglish: Bool { usesEnglish }

    /// 中英切换文案助手。
    func text(_ zh: String, en: String) -> String {
        usesEnglish ? en : zh
    }

    /// iOS may restart the app when its preferred language changes.
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
/// 直接读 Bundle 的系统本地化选择，不依赖 MainActor 隔离的语言管理器。
enum L10n {
    nonisolated static func t(_ zh: String, _ en: String) -> String {
        usesEnglish ? en : zh
    }

    nonisolated static var usesEnglish: Bool {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return !preferred.hasPrefix("zh")
    }
}
