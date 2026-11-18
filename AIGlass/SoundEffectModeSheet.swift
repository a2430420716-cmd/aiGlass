import SwiftUI

enum SoundEffectMode: UInt8, CaseIterable, Identifiable {
    case standard = 0
    case powerful = 1
    case quiet = 2

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .standard: L10n.t("标准", "Standard")
        case .powerful: L10n.t("澎湃", "Dynamic")
        case .quiet: L10n.t("静谧", "Quiet")
        }
    }

    var iconName: String {
        switch self {
        case .standard: "android_sound_standard"
        case .powerful: "android_sound_powerful"
        case .quiet: "android_sound_quiet"
        }
    }

    var cardTitle: String {
        switch self {
        case .standard: L10n.t("标准音效", "Standard")
        case .powerful: L10n.t("澎湃音效", "Dynamic")
        case .quiet: L10n.t("静谧音效", "Quiet")
        }
    }

    var cardIconName: String {
        switch self {
        case .standard: "android_home_sound_standard"
        case .powerful: "android_home_sound_powerful"
        case .quiet: "android_home_sound_quiet"
        }
    }
}

struct SoundEffectModeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selectedMode: SoundEffectMode
    let onSelect: (SoundEffectMode) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(L10n.t("音效模式", "Sound mode"))
                .font(AppTheme.notoSansSC(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 12) {
                ForEach(SoundEffectMode.allCases) { mode in
                    SoundEffectOptionView(
                        mode: mode,
                        isSelected: selectedMode == mode
                    ) {
                        onSelect(mode)
                        dismiss()
                    }
                }
            }

            Button {
                dismiss()
            } label: {
                Text(L10n.t("取消", "Cancel"))
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.cardBackground)
    }
}

private struct SoundEffectOptionView: View {
    let mode: SoundEffectMode
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Image(mode.iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 60, height: 60)

                Text(mode.title)
                    .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 124)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 246 / 255, green: 203 / 255, blue: 217 / 255),
                                        Color(red: 196 / 255, green: 231 / 255, blue: 229 / 255)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(Color(red: 229 / 255, green: 229 / 255, blue: 229 / 255)),
                        lineWidth: isSelected ? 3 : 1
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image("android_sound_check_red")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .offset(x: 8, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    SoundEffectModeSheet(selectedMode: .standard, onSelect: { _ in })
}
