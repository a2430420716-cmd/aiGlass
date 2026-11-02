import SwiftUI

/// 切换配对准备页实现。`.staticGuide` 为设计稿静态页；`.legacy` 为原 API/WebView 版本（暂保留）。
enum PairingPreparationPageKind {
    case staticGuide
    case legacy

    static let current: Self = .staticGuide
}

/// 设计稿静态配对准备页（开机 + 内侧指示灯两步说明）。
struct StaticPairingPreparationView: View {
    let onBack: () -> Void

    @EnvironmentObject private var pairingCoordinator: PairingCoordinator

    private var steps: [(title: String, imageName: String, description: String)] {
        [
            (
                L10n.t("一、将眼镜开机", "1. Power on the glasses"),
                "pairing_power_on_1",
                L10n.t(
                    "拨动电源键开机，内侧指示灯会开始闪烁。开机完成时，指示灯熄灭且听到语音提示(若无反应，请先尝试为眼镜充电)。",
                    "Slide the power switch to turn on. The inner LED will blink. When ready, the LED turns off and you hear a voice prompt (if no response, try charging first)."
                )
            ),
            (
                L10n.t("二、确认内侧指示灯闪烁", "2. Confirm the inner LED is blinking"),
                "pairing_inner_indicator",
                L10n.t("指示灯闪烁说明进入配对状态。", "A blinking LED means pairing mode is active.")
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        stepSection(
                            title: step.title,
                            imageName: step.imageName,
                            description: step.description
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }

            startPairingButton
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("MOCO AI眼镜配对准备", "MOCO AI Glasses Pairing Prep"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 44, alignment: .leading)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func stepSection(title: String, imageName: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            Image(imageName)
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(AppTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: AppTheme.cardShadow, radius: 8, y: 2)

            Text(description)
                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startPairingButton: some View {
        Button {
            pairingCoordinator.startPairing()
        } label: {
            Text(L10n.t("开始配对", "Start Pairing"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }
}

#Preview {
    CompatibleNavigationStack {
        StaticPairingPreparationView(onBack: {})
            .environmentObject(PairingCoordinator())
    }
}
