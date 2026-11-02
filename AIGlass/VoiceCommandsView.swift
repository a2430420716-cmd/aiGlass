import SwiftUI

/// Reference phrases only; opening this page does not send commands to the glasses.
struct VoiceCommandsView: View {
    @Environment(\.dismiss) private var dismiss

    private let gridColor = Color(red: 0.75, green: 0.75, blue: 0.75)
    private let shadedBackground = Color(red: 0.94, green: 0.95, blue: 0.96)

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    commandTable(labelWidth: (geometry.size.width - 32) / 3)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                }
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("语音指令", "Voice Commands"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("返回", "Back"))

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func commandTable(labelWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            commandGroup(
                title: L10n.t("唤醒词", "Wake Words"),
                phrases: [L10n.t("嗨，眸刻 / 嘿，眸刻", "Hi MOCO / Hey MOCO")],
                labelWidth: labelWidth,
                shaded: true
            )
            gridLine
            commandGroup(
                title: L10n.t("拍摄指令", "Camera Commands"),
                phrases: [
                    L10n.t("开始拍照", "Take a photo"),
                    L10n.t("开始录像", "Start recording")
                ],
                labelWidth: labelWidth
            )
            gridLine
            commandGroup(
                title: L10n.t("播放指令", "Playback Commands"),
                phrases: [
                    L10n.t("播放音乐", "Play music"),
                    L10n.t("停止播放（音乐）", "Stop playing music"),
                    L10n.t("播放下一曲 / 下一首", "Play the next track"),
                    L10n.t("播放上一曲 / 上一首", "Play the previous track"),
                    L10n.t("调高音量 /（声音）音量大一点", "Turn up the volume / Louder"),
                    L10n.t("调低音量 /（声音）音量小一点", "Turn down the volume / Quieter")
                ],
                labelWidth: labelWidth,
                shaded: true
            )
            gridLine
            commandGroup(
                title: L10n.t("通话指令", "Call Commands"),
                phrases: [
                    L10n.t("接听电话", "Answer the call"),
                    L10n.t("拒接电话", "Reject the call"),
                    L10n.t("挂断电话", "Hang up")
                ],
                labelWidth: labelWidth
            )
        }
        .font(AppTheme.notoSansSC(size: 13, weight: .regular))
        .foregroundStyle(AppTheme.primaryText)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(gridColor, lineWidth: 0.5)
        }
    }

    private func commandGroup(
        title: String,
        phrases: [String],
        labelWidth: CGFloat,
        shaded: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(phrases.indices, id: \.self) { index in
                if index > 0 { gridLine }
                Text(phrases[index])
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(minHeight: 32)
            }
        }
        .padding(.leading, labelWidth + 0.5)
        .overlay(alignment: .leading) {
            HStack(spacing: 0) {
                Text(title)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .frame(width: labelWidth)
                gridColor.frame(width: 0.5)
            }
            .frame(width: labelWidth + 0.5)
            .accessibilityHidden(true)
        }
        .background(shaded ? shadedBackground : AppTheme.cardBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(([title] + phrases).joined(separator: ", "))
    }

    private var gridLine: some View {
        gridColor.frame(height: 0.5)
    }
}

#Preview {
    CompatibleNavigationStack {
        VoiceCommandsView()
    }
}
