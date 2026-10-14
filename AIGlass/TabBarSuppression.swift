import SwiftUI

private struct TabBarSuppressionCountKey: EnvironmentKey {
    static let defaultValue: Binding<Int>? = nil
}

extension EnvironmentValues {
    var tabBarSuppressionCount: Binding<Int>? {
        get { self[TabBarSuppressionCountKey.self] }
        set { self[TabBarSuppressionCountKey.self] = newValue }
    }
}

private struct SuppressTabBarOnAppearModifier: ViewModifier {
    let enabled: Bool
    @Environment(\.tabBarSuppressionCount) private var suppressionCount
    @State private var isSuppressing = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard enabled, !isSuppressing, let suppressionCount else { return }
                isSuppressing = true
                suppressionCount.wrappedValue += 1
            }
            .onDisappear {
                guard isSuppressing, let suppressionCount else { return }
                isSuppressing = false
                suppressionCount.wrappedValue = max(0, suppressionCount.wrappedValue - 1)
            }
    }
}

extension View {
    /// 页面可见时抑制底部 TabBar；嵌套 push/pop 用引用计数，避免父页 onDisappear 误恢复 TabBar。
    func suppressTabBarOnAppear(enabled: Bool = true) -> some View {
        modifier(SuppressTabBarOnAppearModifier(enabled: enabled))
    }
}
