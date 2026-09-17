import SwiftUI
import UIKit

struct AIChatView: View {
    @ObservedObject private var session = AIChatSession.shared
    @ObservedObject private var voiceChat = AIVoiceChatManager.shared
    @ObservedObject var visionTransfer: AiVisionTransferManager
    @Binding var showsTabBar: Bool
    var token: String?

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var pairingCoordinator: PairingCoordinator
    @State private var navigateToSettings = false
    @State private var settingsAlertMessage: String?
    @State private var previewImage: AIChatImagePreviewItem?

    var body: some View {
        CompatibleNavigationStack {
            VStack(spacing: 0) {
                header

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        // VStack：历史页量不大；LazyVStack + 立刻 scrollTo 易空白，要手动滑才出内容。
                        VStack(spacing: 20) {
                            if session.messages.isEmpty {
                                if session.isLoadingHistory {
                                    ProgressView()
                                        .padding(.top, 48)
                                } else {
                                    emptyHint
                                }
                            } else {
                                ForEach(session.messages) { item in
                                    messageRow(item)
                                        .id(item.id)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("chatBottom")
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                    .refreshable {
                        guard session.canLoadMoreHistory else { return }
                        await session.loadMoreHistory(token: token)
                    }
                    // 仅末条变化时滚到底（新消息 / 首次加载）；下拉更早记录不改 last.id。
                    .onChangeCompat(of: session.messages.last?.id) { _ in
                        scrollChatToBottom(proxy: proxy)
                    }
                    .onAppear {
                        if !session.messages.isEmpty {
                            scrollChatToBottom(proxy: proxy, animated: false)
                        }
                    }
                }

                voiceActionBar
            }
            // 对齐 Android `background_app`：AI 对话页始终使用 #F5F5F5，
            // 不跟随系统深色模式切换背景。
            .background(AppTheme.background.ignoresSafeArea())
            .background {
                NavigationLink(
                    isActive: $navigateToSettings,
                    destination: {
                        GlassesSettingsView(device: connectedSettingsDevice)
                    },
                    label: { EmptyView() }
                )
                .hidden()
            }
        }
        .task(id: token) {
            await session.refreshHistoryOnEnter(token: token)
        }
        .onChangeCompat(of: navigateToSettings) { active in
            showsTabBar = !active
        }
        .fullScreenCover(item: $previewImage) { item in
            AIChatImagePreviewView(image: item.image)
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { settingsAlertMessage != nil },
            set: { if !$0 { settingsAlertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(settingsAlertMessage ?? "")
        }
    }

    private var emptyHint: some View {
        Text(L10n.t("点击下方「语音提问」，对眼镜说话；也可在首页开始智能图像识别", "Tap Voice Ask below to speak to the glasses, or start image recognition from Home"))
            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
            .foregroundStyle(AppTheme.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 48)
    }

    private var voiceActionBar: some View {
        VStack(spacing: 8) {
            if case .failed(let message) = voiceChat.phase {
                Text(message)
                    .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .multilineTextAlignment(.center)
            } else if !voiceChat.statusText.isEmpty {
                Text(voiceChat.statusText)
                    .font(AppTheme.notoSansSC(size: 12, weight: .medium))
                    .foregroundStyle(
                        voiceChat.phase == .listening ? AppTheme.accent : AppTheme.secondaryText
                    )
            }

            Button {
                _ = voiceChat.toggleManualSession()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: voiceConversationActive ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                    Text(voiceChat.actionButtonTitle)
                        .font(AppTheme.notoSansSC(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    voiceConversationActive
                        ? AppTheme.accent
                        : Color.black.opacity(voiceChat.isActionEnabled ? 0.88 : 0.35)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!voiceChat.isActionEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.white.opacity(0.92))
    }

    private var voiceConversationActive: Bool {
        switch voiceChat.phase {
        case .waiting, .listening, .processing, .speaking:
            return true
        case .idle, .failed:
            return false
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.t("AI对话记录", "AI Chat History"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            Spacer()

            if case .receiving(let received, let total) = visionTransfer.phase, total > 0 {
                let percent = min(100, max(0, Int((Double(received) / Double(total) * 100).rounded())))
                Text("\(percent)%")
                    .font(AppTheme.notoSansSC(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Button(action: openSettings) {
                Image("setting_icon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var connectedSettingsDevice: DeviceCardData? {
        let ble = pairingCoordinator.astraA1BleManager
        let liveID = nonEmpty(ble.deviceBluetoothIdentifier) ?? nonEmpty(ble.savedPeripheralUUIDString)
        let liveSN = nonEmpty(ble.deviceSN)
        let devices = authSession.userInfo?.device ?? []

        if let liveID,
           let match = devices.first(where: {
               $0.serialNumber.caseInsensitiveCompare(liveID) == .orderedSame
           }) {
            return DeviceCardData(device: match)
        }
        if let liveSN,
           let match = devices.first(where: {
               $0.hardwareSN?.caseInsensitiveCompare(liveSN) == .orderedSame
                   || $0.serialNumber.caseInsensitiveCompare(liveSN) == .orderedSame
           }) {
            return DeviceCardData(device: match)
        }
        if devices.count == 1, let only = devices.first {
            return DeviceCardData(device: only)
        }
        guard let liveID else { return nil }
        return DeviceCardData(
            id: "live-\(liveID)",
            name: ble.deviceName,
            modelName: ble.deviceModel,
            serialNumber: liveID,
            hardwareSN: liveSN,
            batteryPercent: ble.deviceBatteryPercent,
            imageName: "glass2",
            isFindDevice: false,
            isCharging: ble.deviceIsCharging,
            isConnected: true
        )
    }

    private func openSettings() {
        guard pairingCoordinator.astraA1BleManager.isReady else {
            settingsAlertMessage = L10n.t("设备未连接", "Device not connected")
            return
        }
        guard connectedSettingsDevice != nil else {
            settingsAlertMessage = L10n.t("未找到当前连接设备", "Connected device not found")
            return
        }
        navigateToSettings = true
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    @ViewBuilder
    private func messageRow(_ item: AIChatItem) -> some View {
        switch item.kind {
        case .timestamp(let text):
            timestampView(text)
        case .userText(let text):
            userMessageView(text: text, image: nil, loading: nil)
        case .userImage(let data):
            userMessageView(text: "", image: UIImage(data: data), loading: nil)
        case .userRemoteImage(let url, let text):
            remoteMediaMessageView(isUser: true, url: url, text: text, isVideo: false)
        case .aiRemoteImage(let url, let text):
            remoteMediaMessageView(isUser: false, url: url, text: text, isVideo: false)
        case .userVideo(let url, let text):
            remoteMediaMessageView(isUser: true, url: url, text: text, isVideo: true)
        case .aiVideo(let url, let text):
            remoteMediaMessageView(isUser: false, url: url, text: text, isVideo: true)
        case .userLoading(let text):
            userMessageView(text: text, image: nil, loading: text)
        case .userVoice:
            // Android AI 页忽略 con_type=3，实时流也不显示用户语音气泡/时长。
            EmptyView()
        case .aiVoice(_, _, let text):
            // 兼容旧的内存消息：只显示文字，不显示 AI 语音气泡。
            if let text, !text.isEmpty {
                aiMessageView(text)
            }
        case .aiText(let text):
            aiMessageView(text)
        case .error(let text):
            errorMessageView(text)
        }
    }

    private func userVoiceMessageView(
        messageID: UUID,
        filePath: String,
        durationSeconds: Int,
        recognition: AIChatItem.VoiceRecognition
    ) -> some View {
        let isPlaying = voiceChat.playingVoiceMessageID == messageID
        let bubbleWidth = CGFloat(min(168, max(84, 64 + durationSeconds * 6)))

        return HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    Text(L10n.t("我", "Me"))
                        .font(AppTheme.notoSansSC(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                    userAvatar
                }

                Button {
                    voiceChat.togglePlayback(messageID: messageID, filePath: filePath)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.system(size: 16, weight: .semibold))

                        Text(formatVoiceDuration(durationSeconds))
                            .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                    }
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: bubbleWidth, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.66, green: 0.90, blue: 0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                switch recognition {
                case .recognizing:
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(L10n.t("正在识别...", "Recognizing..."))
                            .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                case .recognized(let text):
                    if !text.isEmpty {
                        Text(text)
                            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                            .foregroundStyle(AppTheme.primaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AppTheme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                case .failed(let message):
                    Text(message)
                        .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                        .foregroundStyle(Color.red.opacity(0.85))
                }
            }
        }
    }

    private func formatVoiceDuration(_ seconds: Int) -> String {
        let value = max(1, seconds)
        if value < 60 {
            return "\(value)\""
        }
        let minutes = value / 60
        let remain = value % 60
        return String(format: "%d'%02d\"", minutes, remain)
    }

    private func aiVoiceMessageView(
        messageID: UUID,
        source: AIChatItem.AIVoiceSource,
        durationSeconds: Int?,
        text: String?
    ) -> some View {
        let isPlaying = voiceChat.playingAIVoiceMessageID == messageID
        let seconds = durationSeconds ?? 0
        let bubbleWidth = CGFloat(min(168, max(96, 82 + seconds * 5)))

        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    aiAvatar
                    Text("MOCO")
                        .font(AppTheme.notoSansSC(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Button {
                    voiceChat.toggleAIResponsePlayback(messageID: messageID, source: source)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isPlaying ? "speaker.wave.3.fill" : "speaker.wave.2")
                            .font(.system(size: 17, weight: .semibold))

                        HStack(spacing: 3) {
                            ForEach(0..<5, id: \.self) { index in
                                Capsule()
                                    .frame(width: 3, height: CGFloat(8 + (index % 3) * 4))
                            }
                        }

                        if let durationSeconds {
                            Text(formatVoiceDuration(durationSeconds))
                                .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                        }
                    }
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: bubbleWidth, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.98, green: 0.97, blue: 0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                if let text, !text.isEmpty {
                    Text(text)
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.98, green: 0.97, blue: 0.94))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }

            Spacer(minLength: 48)
        }
    }

    private func timestampView(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.notoSansSC(size: 13, weight: .regular))
            .foregroundStyle(AppTheme.secondaryText)
            .frame(maxWidth: .infinity)
    }

    private func userMessageView(text: String, image: UIImage?, loading: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 6) {
                    Text(L10n.t("我", "Me"))
                        .font(AppTheme.notoSansSC(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)

                    userAvatar
                }

                let bubbleText = loading ?? text
                if !bubbleText.isEmpty {
                    Text(bubbleText)
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(AppTheme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if loading != nil {
                    ProgressView()
                        .padding(.trailing, 4)
                }

                if let image {
                    Button {
                        previewImage = AIChatImagePreviewItem(image: image)
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 160, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func aiMessageView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    aiAvatar

                    Text("MOCO")
                        .font(AppTheme.notoSansSC(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Text(text)
                    .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineSpacing(4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.98, green: 0.97, blue: 0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Spacer(minLength: 48)
        }
    }

    private func remoteMediaMessageView(
        isUser: Bool,
        url: String,
        text: String?,
        isVideo: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 10) {
                HStack(spacing: 6) {
                    if !isUser { aiAvatar }
                    Text(isUser ? L10n.t("我", "Me") : "MOCO")
                        .font(AppTheme.notoSansSC(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                    if isUser { userAvatar }
                }

                if let text, !text.isEmpty {
                    Text(text)
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            isUser
                                ? AppTheme.cardBackground
                                : Color(red: 0.98, green: 0.97, blue: 0.94)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if isVideo {
                    Link(destination: URL(string: url) ?? URL(string: "about:blank")!) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.black.opacity(0.78))
                                .frame(width: 200, height: 120)
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.white)
                        }
                    }
                } else {
                    // OSS 常带 Content-Disposition: attachment，AsyncImage 偶发失败；改 URLSession 解码。
                    ChatRemoteImage(urlString: url) { image in
                        previewImage = AIChatImagePreviewItem(image: image)
                    }
                        .frame(width: 160, height: 160)
                        .clipped()
                        .background(AppTheme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            if !isUser { Spacer(minLength: 48) }
        }
    }

    private func scrollChatToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        guard session.messages.last != nil else { return }
        Task { @MainActor in
            // 等一帧布局完成再滚，避免内容高度未算完导致空白视口。
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("chatBottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
        }
    }

    private func errorMessageView(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.notoSansSC(size: 13, weight: .regular))
            .foregroundStyle(Color.red.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var userAvatar: some View {
        Circle()
            .fill(Color(red: 0.90, green: 0.90, blue: 0.90))
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white)
            }
    }

    private var aiAvatar: some View {
        Image("icon2")
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
    }
}

/// 聊天远程图：URLSession 拉字节再 UIImage 解码（兼容 OSS attachment 头）。
private struct ChatRemoteImage: View {
    let urlString: String
    let onImageTap: (UIImage) -> Void

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let image {
                onImageTap(image)
            }
        }
        .task(id: urlString) {
            await load()
        }
    }

    private func load() async {
        image = nil
        failed = false
        guard let url = URL(string: urlString) else {
            print("[visit_log][image][ui] invalid URL string=\(urlString)")
            failed = true
            return
        }
        print("[visit_log][image][ui] load url=\(urlString)")
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            AppRequestHeaders.apply(to: &request)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let mime = (response as? HTTPURLResponse)?.mimeType ?? "nil"
            guard let decoded = UIImage(data: data) else {
                print(
                    "[visit_log][image][ui] decode fail status=\(status) mime=\(mime) "
                        + "bytes=\(data.count) url=\(urlString)"
                )
                failed = true
                return
            }
            print(
                "[visit_log][image][ui] success status=\(status) mime=\(mime) "
                    + "bytes=\(data.count) size=\(Int(decoded.size.width))x\(Int(decoded.size.height)) "
                    + "url=\(urlString)"
            )
            image = decoded
        } catch {
            print(
                "[visit_log][image][ui] failure url=\(urlString) "
                    + "error=\(error.localizedDescription)"
            )
            failed = true
        }
    }
}

private struct AIChatImagePreviewItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct AIChatImagePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            ZoomableImageScrollView(image: image)
                .ignoresSafeArea()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 18)
            .padding(.top, 12)
        }
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let point = recognizer.location(in: imageView)
            let zoomScale = min(2.5, scrollView.maximumZoomScale)
            let width = scrollView.bounds.width / zoomScale
            let height = scrollView.bounds.height / zoomScale
            scrollView.zoom(
                to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                animated: true
            )
        }
    }
}

#Preview {
    AIChatView(
        visionTransfer: AiVisionTransferManager(),
        showsTabBar: .constant(true),
        token: nil
    )
    .environmentObject(AuthSession())
    .environmentObject(PairingCoordinator())
    .environmentObject(DeviceFirmwareUpdateCoordinator())
    .environmentObject(BluetoothOtaUpgradeManager())
    .environmentObject(MainTabRouter())
}
