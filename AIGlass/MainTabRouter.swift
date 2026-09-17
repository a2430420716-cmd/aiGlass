import Combine
import SwiftUI

/// 主 Tab 切换（首页识图入口跳到 AI）。
@MainActor
final class MainTabRouter: ObservableObject {
    @Published var selectedTab: TabItem = .glasses
    /// >0 时主界面立即收起 TabBar 与底部 inset（沉浸页 push 前调用）。
    @Published private(set) var immersiveCoverCount = 0
    /// 新手引导等黑底页：push 前把导航容器底改成黑色，避免过渡露白缝。
    @Published private(set) var usesBlackNavigationBackdrop = false

    var hidesTabBarForImmersiveCover: Bool {
        immersiveCoverCount > 0
    }

    var navigationBackdropColor: Color {
        usesBlackNavigationBackdrop ? .black : AppTheme.background
    }

    func openAITab() {
        selectedTab = .ai
    }

    func beginImmersiveCover() {
        immersiveCoverCount += 1
    }

    func endImmersiveCover() {
        immersiveCoverCount = max(0, immersiveCoverCount - 1)
    }

    func setBlackNavigationBackdrop(_ enabled: Bool) {
        usesBlackNavigationBackdrop = enabled
    }

    /// 切换语言会整体重建主界面，沉浸页计数随之失效，需归零否则 TabBar 永远藏着。
    func resetChromeState() {
        immersiveCoverCount = 0
        usesBlackNavigationBackdrop = false
    }

    /// 先释放 TabBar 底部 inset，再执行 push / path 更新，避免过渡期底部留空。
    /// - Parameter blackBackdrop: 黑底沉浸页在 delay 期间就把导航容器涂黑。
    func performPushAfterReleasingTabInset(
        blackBackdrop: Bool = false,
        _ action: @escaping () -> Void
    ) {
        beginImmersiveCover()
        if blackBackdrop {
            usesBlackNavigationBackdrop = true
        }
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                action()
            }
        }
    }
}
