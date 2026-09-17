import SwiftUI
import UIKit

/// 将 UINavigationController 底层背景设为 App 背景色，避免 push 动画期间底部闪白。
struct NavigationControllerBackgroundFix: UIViewControllerRepresentable {
    let uiColor: UIColor

    func makeUIViewController(context: Context) -> Controller {
        Controller(uiColor: uiColor)
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.uiColor = uiColor
        uiViewController.apply()
    }

    final class Controller: UIViewController {
        var uiColor: UIColor

        init(uiColor: UIColor) {
            self.uiColor = uiColor
            super.init(nibName: nil, bundle: nil)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            apply()
        }

        func apply() {
            // 先涂当前页所在 Hosting，避免 push 过渡中间露出系统白底竖缝。
            var pageAncestor: UIViewController? = parent
            while let current = pageAncestor {
                current.view.backgroundColor = uiColor
                if String(describing: type(of: current)).contains("Hosting") {
                    break
                }
                pageAncestor = current.parent
            }

            guard let navigationController else { return }
            navigationController.view.backgroundColor = uiColor

            var parent: UIViewController? = navigationController.parent
            while let current = parent {
                current.view.backgroundColor = uiColor
                if String(describing: type(of: current)).contains("Hosting") {
                    break
                }
                parent = current.parent
            }
        }
    }
}

extension View {
    func navigationControllerBackground(_ color: Color = AppTheme.background) -> some View {
        background(
            NavigationControllerBackgroundFix(uiColor: UIColor(color))
                .frame(width: 0, height: 0)
        )
    }

    /// 操作指南等浅色 push 页：铺满主题底 + 涂导航容器，消除过渡白缝。
    func appNavigationPageBackground(_ color: Color = AppTheme.background) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color.ignoresSafeArea())
            .compatibleNavigationContainerBackground(color)
            .navigationControllerBackground(color)
    }
}

extension AppTheme {
    static var uiBackground: UIColor {
        UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
    }
}
