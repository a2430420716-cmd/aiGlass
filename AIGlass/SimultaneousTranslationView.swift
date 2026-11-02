import SwiftUI

/// 同声传译：对齐安卓 `SimultaneousTranslationActivity`。
struct SimultaneousTranslationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession

    @StateObject private var controller = SimultaneousTranslationController()
    @State private var sourcePanelRatio: CGFloat = 0.5
    @State private var dragStartRatio: CGFloat = 0.5
    @State private var isDraggingPanels = false
    @State private var showsLanguageSelect = false
    @State private var selectingSource = true
    @State private var showsRecordList = false

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            languagePanel

            GeometryReader { proxy in
                let separatorHeight: CGFloat = 20
                let available = max(360, proxy.size.height - separatorHeight)
                let sourceHeight = max(120, available * sourcePanelRatio)
                let targetHeight = max(120, available - sourceHeight)

                VStack(spacing: 0) {
                    translationPanel(
                        language: controller.sourceLanguage,
                        text: controller.sourceText,
                        placeholder: controller.isRecording ? L10n.t("正在识别原文…", "Recognizing source…") : L10n.t("此处显示原文", "Source text appears here"),
                        showsRecordButton: false
                    )
                    .frame(height: sourceHeight)

                    dragSeparator
                        .frame(height: separatorHeight)
                        .gesture(dragGesture(totalHeight: available))

                    translationPanel(
                        language: controller.targetLanguage,
                        text: controller.targetText,
                        placeholder: controller.isRecording ? L10n.t("正在生成译文…", "Generating translation…") : L10n.t("此处显示译文", "Translation appears here"),
                        showsRecordButton: true
                    )
                    .frame(height: targetHeight)
                }
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .onAppear {
            controller.start(token: authSession.token)
        }
        .onDisappear {
            controller.stop()
        }
        .compatibleNavigationDestination(isPresented: $showsLanguageSelect) {
            TranslationLanguageSelectView(
                selectedLanguage: selectingSource
                    ? controller.sourceLanguage
                    : controller.targetLanguage
            ) { language in
                if selectingSource {
                    controller.updateSourceLanguage(language)
                } else {
                    controller.updateTargetLanguage(language)
                }
            }
        }
        .compatibleNavigationDestination(isPresented: $showsRecordList) {
            TranslationRecordListView()
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { controller.alertMessage != nil },
            set: { if !$0 { controller.alertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(controller.alertMessage ?? "")
        }
        .alert(L10n.t("提示", "Notice"), isPresented: $controller.confirmExitWhileRecording) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("确定", "OK")) {
                controller.prepareExitThen { dismiss() }
            }
        } message: {
            Text(L10n.t("当前正在录音，是否保存并退出？", "Recording in progress. Save and exit?"))
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button {
                controller.handleBackRequest {
                    controller.stop()
                    dismiss()
                }
            } label: {
                Image("android_nav_back")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .frame(width: 44, height: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("返回", "Back"))

            Text(L10n.t("同声传译", "Simultaneous Interpretation"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)

            HStack(spacing: 4) {
                Button {
                    controller.toggleGlassesSound()
                } label: {
                    Image(controller.glassesSoundEnabled ? "icon_glasses_fy_yes" : "icon_glasses_fy_no")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.glassesSoundEnabled ? L10n.t("关闭眼镜播报", "Mute glasses playback") : L10n.t("开启眼镜播报", "Enable glasses playback"))

                Button {
                    showsRecordList = true
                } label: {
                    Image("android_translation_more")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("同声传译记录", "Interpretation History"))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var languagePanel: some View {
        HStack(spacing: 14) {
            languageSelector(
                label: L10n.t("源语言", "Source"),
                language: controller.sourceLanguage,
                alignment: .leading
            ) {
                guard !controller.isRecording else { return }
                selectingSource = true
                showsLanguageSelect = true
            }

            Button {
                controller.swapLanguages()
            } label: {
                Image("android_translation_swap")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(controller.isRecording)
            .opacity(controller.isRecording ? 0.45 : 1)
            .accessibilityLabel(L10n.t("互换语言", "Swap Languages"))

            languageSelector(
                label: L10n.t("目标语言", "Target"),
                language: controller.targetLanguage,
                alignment: .trailing
            ) {
                guard !controller.isRecording else { return }
                selectingSource = false
                showsLanguageSelect = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func languageSelector(
        label: String,
        language: String,
        alignment: HorizontalAlignment,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: alignment, spacing: 8) {
                Text(label)
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)

                HStack(spacing: 8) {
                    Text(TranslationLanguage.fromDisplayName(language).displayName)
                        .font(AppTheme.notoSansSC(size: 17, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                    Image("android_translation_dropdown")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 8, height: 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        }
        .buttonStyle(.plain)
        .disabled(controller.isRecording)
        .opacity(controller.isRecording ? 0.55 : 1)
    }

    private func translationPanel(
        language: String,
        text: String,
        placeholder: String,
        showsRecordButton: Bool
    ) -> some View {
        ZStack {
            AppTheme.cardBackground

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(AppTheme.notoSansSC(size: 18, weight: .regular))
                    .foregroundStyle(Color(red: 0.82, green: 0.82, blue: 0.82))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(TranslationLanguage.fromDisplayName(language).displayName)
                            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                            .foregroundStyle(AppTheme.secondaryText)

                        Text(text)
                            .font(AppTheme.notoSansSC(size: 18, weight: .regular))
                            .foregroundStyle(AppTheme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineSpacing(6)
                    }
                    .padding(24)
                }
            }

            if showsRecordButton {
                VStack {
                    Spacer()

                    Button {
                        controller.toggleRecording()
                    } label: {
                        ZStack {
                            Image("android_translation_record_background")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 76, height: 76)
                            Image(controller.isRecording ? "android_translation_record_stop" : "android_translation_record_mic")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 36, height: 36)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(controller.isRecording ? L10n.t("停止录音", "Stop Recording") : L10n.t("开始录音", "Start Recording"))
                    .padding(.bottom, 38)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var dragSeparator: some View {
        ZStack {
            AppTheme.background

            Capsule()
                .fill(Color(red: 0.84, green: 0.84, blue: 0.84))
                .frame(width: 118, height: 5)
        }
        .contentShape(Rectangle())
    }

    private func dragGesture(totalHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !isDraggingPanels {
                    isDraggingPanels = true
                    dragStartRatio = sourcePanelRatio
                }
                let delta = value.translation.height / max(totalHeight, 1)
                sourcePanelRatio = (dragStartRatio + delta).clamped(to: 0.28...0.72)
            }
            .onEnded { _ in
                isDraggingPanels = false
                dragStartRatio = sourcePanelRatio
            }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    CompatibleNavigationStack {
        SimultaneousTranslationView()
            .environmentObject(AuthSession())
    }
}
