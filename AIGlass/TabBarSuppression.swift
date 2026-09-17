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
    @Environment(\.tabBarSuppressionCount) private var suppressionCount

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let suppressionCount else { return }
                suppressionCount.wrappedValue += 1
            }
            .onDisappear {
                guard let suppressionCount else { return }
                suppressionCount.wrappedValue = max(0, suppressionCount.wrappedValue - 1)
            }
    }
}

extension View {
    /// 页面可见时抑制底部 TabBar；嵌套 push/pop 用引用计数，避免父页 onDisappear 误恢复 TabBar。
    func suppressTabBarOnAppear() -> some View {
        modifier(SuppressTabBarOnAppearModifier())
    }
}
