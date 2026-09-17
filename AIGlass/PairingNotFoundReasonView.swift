import SwiftUI

struct PairingNotFoundReasonView: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    preparationSection(
                        title: L10n.t("一、将眼镜开机", "1. Power on the glasses"),
                        imageName: "pairing_power_on_1",
                        description: L10n.t(
                            "拨动电源键开机，内侧指示灯会开始闪烁。开机完成时，指示灯熄灭且听到语音提示(若无反应，请先尝试为眼镜充电)。",
                            "Slide the power switch to turn on. The inner LED will blink. When ready, the LED turns off and you hear a voice prompt (if no response, try charging first)."
                        )
                    )

                    preparationSection(
                        title: L10n.t("二、确认内侧指示灯闪烁", "2. Confirm the inner LED is blinking"),
                        imageName: "pairing_inner_indicator",
                        description: L10n.t("指示灯闪烁说明进入配对状态", "A blinking LED means pairing mode is active")
                    )

                    troubleshootingSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
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
                Button {
                    onBack()
                } label: {
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

    private func preparationSection(title: String, imageName: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            imageCard(imageName: imageName)

            Text(description)
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var troubleshootingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("三、若指示灯不闪烁，请执行以下操作", "3. If the LED is not blinking, try the following"))
                .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            imageCard(imageName: "pairing_function_key_3")

            VStack(alignment: .leading, spacing: 16) {
                subStepSection(
                    title: L10n.t("连续短按5次功能键", "Short-press the function button 5 times"),
                    description: L10n.t(
                        "内侧指示灯会开始闪烁，并出现语音提示，已进入重置流程。",
                        "The inner LED will blink with a voice prompt — reset has started."
                    )
                )

                subStepSection(
                    title: L10n.t("再长按功能键8S", "Then long-press the function button for 8s"),
                    description: L10n.t(
                        "长按功能键8s，开始重置眼镜。请等待指示灯由闪烁变为常亮，然后熄灭，标志着重置完成。待指示灯重新开始闪烁，可开始配对。",
                        "Long-press 8s to reset. Wait until the LED goes from blinking to solid, then off — reset is done. When it blinks again, you can pair."
                    )
                )
            }
        }
    }

    private func imageCard(imageName: String) -> some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func subStepSection(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppTheme.notoSansSC(size: 14, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            Text(description)
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    CompatibleNavigationStack {
        PairingNotFoundReasonView(onBack: {})
    }
}
