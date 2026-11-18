import SwiftUI

struct AiVisionModeDialog: View {
    let selectedLevel: UInt8
    let onCancel: () -> Void
    let onSelect: (AiVisionSettings.Level) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onCancel)

                VStack(spacing: 0) {
                    Text(L10n.t("智能图像识别模式选择", "AI vision mode"))
                        .font(AppTheme.notoSansSC(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(AiVisionSettings.Level.allCases) { level in
                                optionRow(level)
                                if level != AiVisionSettings.Level.allCases.last {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: min(360, geometry.size.height * 0.65))

                    Button(action: onCancel) {
                        Text(L10n.t("取消", "Cancel"))
                            .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 520)
                .background(AppTheme.cardBackground)
                .contentShape(Rectangle())
                .onTapGesture {}
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func optionRow(_ level: AiVisionSettings.Level) -> some View {
        let isSelected = selectedLevel == level.rawValue
        return Button {
            onSelect(level)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(level.title)
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(level.subtitle)
                        .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsRadioIndicator(isSelected: isSelected)
            }
            .padding(.vertical, 12)
            .frame(minHeight: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
