import SwiftUI

enum SoundEffectMode: UInt8, CaseIterable, Identifiable {
    case standard = 0
    case powerful = 1
    case quiet = 2

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .standard: L10n.t("标准", "Standard")
        case .powerful: L10n.t("澎湃", "Powerful")
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
        case .standard: L10n.t("标准音效", "Standard Sound")
        case .powerful: L10n.t("澎湃音效", "Powerful Sound")
        case .quiet: L10n.t("静谧音效", "Quiet Sound")
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
        VStack(spacing: 24) {
            Text(L10n.t("音效模式", "Sound Mode"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.primaryText)

            HStack(spacing: 16) {
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
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
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
                    .frame(width: 40, height: 40)

                Text(mode.title)
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isSelected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.965, green: 0.796, blue: 0.851),
                                        Color(red: 0.769, green: 0.906, blue: 0.898)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(Color(red: 0.90, green: 0.90, blue: 0.90)),
                        lineWidth: isSelected ? 3 : 1
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    ZStack {
                        Circle()
                            .fill(AppTheme.accent)
                            .frame(width: 20, height: 20)

                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SoundEffectModeSheet(selectedMode: .standard, onSelect: { _ in })
}
