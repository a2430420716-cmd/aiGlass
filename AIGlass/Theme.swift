import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.96, green: 0.96, blue: 0.96)
    static let accent = Color(red: 0.91, green: 0.36, blue: 0.36)
    static let cardBackground = Color.white
    static let primaryText = Color.black
    static let secondaryText = Color(red: 0.55, green: 0.55, blue: 0.55)
    static let cardCornerRadius: CGFloat = 20
    static let cardShadow = Color.black.opacity(0.04)
}

enum HomeLayout {
    /// 首页所有卡片共用同一左右基线；不限制最大宽度，避免大屏设备边距被放大。
    static let horizontalMargin: CGFloat = 12

    static var contentWidth: CGFloat {
        max(UIScreen.main.bounds.width - horizontalMargin * 2, 280)
    }

    static var deviceCardWidth: CGFloat { contentWidth }
    static let deviceCardHeight: CGFloat = 200
    static var volumeCardWidth: CGFloat { contentWidth }
    static let volumeCardHeight: CGFloat = 90
    static var actionCardWidth: CGFloat {
        (contentWidth - actionCardSpacing) / 2
    }
    static let actionCardHeight: CGFloat = 100
    static let actionCardSpacing: CGFloat = 8
    static let mediaActionCardHeight: CGFloat = 110
    static let featureActionCardHeight: CGFloat = 110
    static let plusButtonSize: CGFloat = 33
    static let screenTitleSize: CGFloat = 18
    static let glassImageWidth: CGFloat = 208
    static let glassImageHeight: CGFloat = 77
}

extension AppTheme {
    static func notoSansSC(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("Noto Sans SC", size: size).weight(weight)
    }
}
