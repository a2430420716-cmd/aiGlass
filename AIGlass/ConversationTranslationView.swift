import SwiftUI

/// 对话翻译页：对齐安卓 `ConversationTranslationActivity` 与设计稿。
struct ConversationTranslationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var pairingCoordinator: PairingCoordinator

    @StateObject private var controller = ConversationTranslationController()
    @State private var showsLanguageSelect = false
    @State private var selectingGlassesLanguage = true
    @State private var showsRecordList = false

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            languagePanel
            messages
            recordControls
        }
        .background(Color(red: 0.965, green: 0.965, blue: 0.965).ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .onAppear {
            controller.start(
                ble: pairingCoordinator.astraA1BleManager,
                token: authSession.token
            )
        }
        .onDisappear {
            controller.stop()
        }
        .compatibleNavigationDestination(isPresented: $showsLanguageSelect) {
            TranslationLanguageSelectView(
                selectedLanguage: selectingGlassesLanguage
                    ? controller.glassesLanguage
                    : controller.phoneLanguage
            ) { language in
                if selectingGlassesLanguage {
                    controller.updateGlassesLanguage(language)
                } else {
                    controller.updatePhoneLanguage(language)
                }
            }
        }
        .compatibleNavigationDestination(isPresented: $showsRecordList) {
            ConversationTranslationRecordListView()
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { controller.alertMessage != nil },
            set: { if !$0 { controller.alertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(controller.alertMessage ?? "")
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("对话翻译", "Conversation Translation"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button {
                    controller.stop()
                    dismiss()
                } label: {
                    Image("android_nav_back")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    showsRecordList = true
                } label: {
                    Image("android_translation_more")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .frame(width: 44, height: 44, alignment: .trailing)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var languagePanel: some View {
        HStack(spacing: 8) {
            languageButton(
                caption: L10n.t("眼镜录入语言", "Glasses Input Language"),
                language: controller.glassesLanguage,
                alignment: .leading,
                frameAlignment: .leading
            ) {
                selectingGlassesLanguage = true
                showsLanguageSelect = true
            }

            Button {
                controller.swapLanguages()
            } label: {
                Image("android_translation_swap")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 28)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(L10n.t("互换语言", "Swap Languages"))
            .disabled(controller.glassesActive || controller.phoneActive)

            languageButton(
                caption: L10n.t("手机录入语言", "Phone Input Language"),
                language: controller.phoneLanguage,
                alignment: .trailing,
                frameAlignment: .trailing
            ) {
                selectingGlassesLanguage = false
                showsLanguageSelect = true
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 72)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func languageButton(
        caption: String,
        language: String,
        alignment: HorizontalAlignment,
        frameAlignment: Alignment,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: alignment, spacing: 6) {
                Text(caption)
                    .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                HStack(spacing: 5) {
                    Text(TranslationLanguage.fromDisplayName(language).displayName)
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                    Image("android_translation_dropdown")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 8, height: 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.glassesActive || controller.phoneActive)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(controller.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .onChangeCompat(of: controller.messages) { messages in
                guard let id = messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private func messageBubble(_ message: ConversationTranslationMessage) -> some View {
        HStack {
            if message.side == .phone { Spacer(minLength: 54) }

            VStack(alignment: .leading, spacing: 5) {
                if !message.sourceText.isEmpty {
                    Text(message.sourceText)
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    Text(message.translatedText.isEmpty ? L10n.t("正在翻译…", "Translating…") : message.translatedText)
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if message.hasSpeech || message.speechData != nil {
                        Button {
                            controller.replay(message)
                        } label: {
                            // 眼镜消息回放走手机；手机消息回放走眼镜。
                            Image(message.side == .glasses
                                  ? "android_translation_phone_speaker"
                                  : "android_translation_glasses_speaker")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.side == .glasses
                ? Color(red: 0.86, green: 0.92, blue: 1.00)
                : Color(red: 0.92, green: 0.87, blue: 1.00))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if message.side == .glasses { Spacer(minLength: 54) }
        }
    }

    private var recordControls: some View {
        HStack {
            recordButton(
                title: controller.glassesStopping ? L10n.t("正在结束…", "Finishing…")
                    : (controller.glassesActive ? L10n.t("停止录音", "Stop Recording") : L10n.t("眼镜录音", "Glasses Record")),
                idleImage: "android_conversation_glasses_record",
                activeImages: [
                    "android_conversation_recording_1",
                    "android_conversation_recording_2",
                    "android_conversation_recording_3",
                    "android_conversation_recording_4"
                ],
                isActive: controller.glassesActive && !controller.glassesStopping,
                isDisabled: controller.phoneActive || controller.glassesStopping,
                action: controller.toggleGlassesRecording
            )

            Spacer()

            recordButton(
                title: controller.phoneActive ? L10n.t("停止录音", "Stop Recording") : L10n.t("手机录音", "Phone Record"),
                idleImage: "android_conversation_phone_record",
                activeImages: [
                    "android_conversation_recording_1",
                    "android_conversation_recording_2",
                    "android_conversation_recording_3",
                    "android_conversation_recording_4"
                ],
                isActive: controller.phoneActive,
                isDisabled: controller.glassesActive,
                action: controller.togglePhoneRecording
            )
        }
        .padding(.horizontal, 58)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    private func recordButton(
        title: String,
        idleImage: String,
        activeImages: [String],
        isActive: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                if isActive {
                    RecordingFrameAnimation(imageNames: activeImages)
                } else {
                    Image(idleImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 60, height: 60)
                }

                Text(title)
                    .font(AppTheme.notoSansSC(size: 17, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
            }
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.45 : 1)
        .disabled(isDisabled)
    }
}

private struct RecordingFrameAnimation: View {
    let imageNames: [String]

    @State private var frameIndex = 0

    var body: some View {
        Image(imageNames[frameIndex % imageNames.count])
            .resizable()
            .scaledToFit()
            .frame(width: 60, height: 60)
            .task {
                frameIndex = 0
                while !Task.isCancelled {
                    // Match main/res/drawable/anim_translation_recording.xml.
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard !Task.isCancelled else { return }
                    frameIndex = (frameIndex + 1) % imageNames.count
                }
            }
    }
}

#Preview {
    CompatibleNavigationStack {
        ConversationTranslationView()
    }
}
