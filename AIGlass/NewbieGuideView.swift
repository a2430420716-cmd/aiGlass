import AVFoundation
import Combine
import SwiftUI

@MainActor
final class NewbieGuideController: ObservableObject {
    @Published var stepIndex = 0
    @Published var guideItems: [DeviceGuideItem] = DeviceGuideItem.newbieGuideDefaults
    @Published var isCompleted = false
    @Published var isLoading = true
    @Published var toastMessage: String?

    private weak var ble: AstraA1BleManager?
    private var guideModeEnabled = false
    private var lastEventType: Int = -1
    private var lastEventTime: Date = .distantPast
    private var toastWorkItem: DispatchWorkItem?

    /// 对齐 Android `NewbieGuideActivity` 音乐播放。
    private var guideMusicPlayer: AVAudioPlayer?
    private var guideMusicIndex = -1
    private let guideMusicNames = [
        "newbie_guide_music_1",
        "newbie_guide_music_2",
        "newbie_guide_music_3"
    ]

    private let stepPlayMusic = 3
    private let stepVolume = 4
    private let stepNextTrack = 5
    private let stepPreviousTrack = 6
    private let stepPauseMusic = 7

    private let expectedEvents: [UInt8] = [
        AstraA1BleProtocol.GuideEventType.cameraClick.rawValue,
        AstraA1BleProtocol.GuideEventType.cameraLongPress.rawValue,
        AstraA1BleProtocol.GuideEventType.cameraClick.rawValue,
        AstraA1BleProtocol.GuideEventType.touchClick.rawValue,
        AstraA1BleProtocol.GuideEventType.touchSwipe.rawValue,
        AstraA1BleProtocol.GuideEventType.touchDoubleClick.rawValue,
        AstraA1BleProtocol.GuideEventType.touchTripleClick.rawValue,
        AstraA1BleProtocol.GuideEventType.touchClick.rawValue,
        AstraA1BleProtocol.GuideEventType.touchLongPress.rawValue
    ]

    private let debounceSeconds: TimeInterval = 0.35
    private let stepStorageKey = "blueSettingData"

    var totalSteps: Int { expectedEvents.count }

    var currentItem: DeviceGuideItem? {
        guard !isCompleted, stepIndex < guideItems.count else { return nil }
        return guideItems[stepIndex]
    }

    func start(ble: AstraA1BleManager, modelName: String, token: String?) {
        self.ble = ble
        // 进入页面即锁定加载态；Task 真正开始前也不能闪出默认眼镜图。
        isLoading = true
        ble.guideEventHandler = { [weak self] eventType in
            Task { @MainActor in
                self?.handleGuideEvent(eventType)
            }
        }
        ensureGuideData()
        saveCurrentStep()
        enterGuideMode()
        Task { await loadGuideData(modelName: modelName, token: token) }
    }

    func stop() {
        stopGuideMusic()
        exitGuideMode()
        UserDefaults.standard.set(0, forKey: stepStorageKey)
        ble?.guideEventHandler = nil
        ble = nil
    }

    func skipCurrentStep() {
        print("[NewbieGuide] skip step=\(stepIndex + 1)")
        advanceStep()
    }

    func restart() {
        isCompleted = false
        stepIndex = 0
        lastEventType = -1
        lastEventTime = .distantPast
        saveCurrentStep()
        enterGuideMode()
        updateGuideMusicForStep()
    }

    private func loadGuideData(modelName: String, token: String?) async {
        isLoading = true
        defer { isLoading = false }

        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ensureGuideData()
            return
        }

        do {
            let items = try await DeviceService.fetchDeviceGuide(modelName: name, token: token)
            if items.count >= expectedEvents.count {
                guideItems = items
            } else {
                ensureGuideData()
            }
        } catch {
            print("[NewbieGuide] load guide failed: \(error.localizedDescription)")
            ensureGuideData()
        }
        saveCurrentStep()
    }

    private func ensureGuideData() {
        if guideItems.count < expectedEvents.count {
            guideItems = DeviceGuideItem.newbieGuideDefaults
        }
    }

    private func enterGuideMode() {
        guard let ble, ble.isReady else {
            showToast(L10n.t("设备未连接", "Not connected"))
            return
        }
        guideModeEnabled = ble.setGuideModeEnabled(true)
        if !guideModeEnabled {
            showToast(L10n.t("设备未连接", "Not connected"))
        }
    }

    private func exitGuideMode() {
        guard guideModeEnabled else { return }
        _ = ble?.setGuideModeEnabled(false)
        guideModeEnabled = false
    }

    private func handleGuideEvent(_ eventType: UInt8) {
        if isCompleted { return }

        let now = Date()
        if Int(eventType) == lastEventType, now.timeIntervalSince(lastEventTime) < debounceSeconds {
            print("[NewbieGuide] ignore duplicate event=\(eventType)")
            return
        }
        lastEventType = Int(eventType)
        lastEventTime = now

        guard stepIndex < expectedEvents.count else { return }
        let expected = expectedEvents[stepIndex]
        print("[NewbieGuide] event=\(eventType) expected=\(expected) step=\(stepIndex + 1)")
        if eventType != expected {
            showToast(L10n.t("请按当前提示操作", "Follow the current prompt"))
            return
        }
        // 对齐 Android：先执行本步音乐动作，再推进步骤
        simulateStepAction(for: stepIndex)
        advanceStep()
    }

    private func advanceStep() {
        if stepIndex >= expectedEvents.count - 1 {
            isCompleted = true
            UserDefaults.standard.set(0, forKey: stepStorageKey)
            exitGuideMode()
            stopGuideMusic()
            return
        }
        stepIndex += 1
        saveCurrentStep()
        updateGuideMusicForStep()
    }

    private func saveCurrentStep() {
        UserDefaults.standard.set(stepIndex + 1, forKey: stepStorageKey)
    }

    private func showToast(_ message: String) {
        toastWorkItem?.cancel()
        toastMessage = message
        let work = DispatchWorkItem { [weak self] in
            if self?.toastMessage == message {
                self?.toastMessage = nil
            }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    // MARK: - Guide Music (align Android NewbieGuideActivity)

    private func simulateStepAction(for step: Int) {
        switch step {
        case stepPlayMusic:
            playGuideMusic(index: 1, restart: true)
        case stepVolume:
            print("[NewbieGuide] simulate volume change")
        case stepNextTrack:
            playGuideMusic(index: nextGuideMusicIndex(), restart: true)
        case stepPreviousTrack:
            playGuideMusic(index: previousGuideMusicIndex(), restart: true)
        case stepPauseMusic:
            pauseGuideMusic()
        case 8:
            print("[NewbieGuide] simulate voice assistant")
        default:
            break
        }
    }

    private func updateGuideMusicForStep() {
        switch stepIndex {
        case stepPlayMusic:
            break
        case stepVolume...stepPauseMusic:
            if guideMusicIndex < 0 {
                playGuideMusic(index: 1, restart: false)
            }
        default:
            stopGuideMusic()
        }
    }

    private func playGuideMusic(index: Int, restart: Bool) {
        let targetIndex = max(0, min(index, guideMusicNames.count - 1))
        if !restart,
           guideMusicIndex == targetIndex,
           guideMusicPlayer?.isPlaying == true {
            return
        }

        if guideMusicIndex != targetIndex || guideMusicPlayer == nil || restart {
            releaseGuideMusicPlayer()
            guard let url = guideMusicURL(at: targetIndex) else {
                print("[NewbieGuide] music file missing: \(guideMusicNames[targetIndex]).mp3")
                return
            }
            do {
                try prepareAudioSession()
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                player.prepareToPlay()
                guideMusicPlayer = player
                guideMusicIndex = targetIndex
            } catch {
                print("[NewbieGuide] create music player failed: \(error.localizedDescription)")
                releaseGuideMusicPlayer()
                return
            }
        }

        guard let player = guideMusicPlayer else { return }
        if player.play() {
            print("[NewbieGuide] music playing: index=\(targetIndex + 1)")
        } else {
            print("[NewbieGuide] start music failed: index=\(targetIndex + 1)")
        }
    }

    private func pauseGuideMusic() {
        guideMusicPlayer?.pause()
        print("[NewbieGuide] music paused: index=\(guideMusicIndex + 1)")
    }

    private func stopGuideMusic() {
        if guideMusicPlayer == nil {
            guideMusicIndex = -1
            return
        }
        releaseGuideMusicPlayer()
        print("[NewbieGuide] music stopped")
    }

    private func releaseGuideMusicPlayer() {
        guideMusicPlayer?.stop()
        guideMusicPlayer = nil
        guideMusicIndex = -1
    }

    private func nextGuideMusicIndex() -> Int {
        if guideMusicIndex < 0 { return 1 }
        return (guideMusicIndex + 1) % guideMusicNames.count
    }

    private func previousGuideMusicIndex() -> Int {
        if guideMusicIndex < 0 { return 1 }
        return (guideMusicIndex - 1 + guideMusicNames.count) % guideMusicNames.count
    }

    private func guideMusicURL(at index: Int) -> URL? {
        let name = guideMusicNames[index]
        if let url = Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Resources") {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: "mp3")
    }

    private func prepareAudioSession() throws {
        try GlassesAudioRouteController.activate(.playback)
    }
}

/// 交互式新手引导：对齐 Android `NewbieGuideActivity`。
struct NewbieGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var ble: AstraA1BleManager
    @StateObject private var controller = NewbieGuideController()

    let modelName: String
    let token: String?
    /// 对齐 Android `finish()`：由外层关掉 `NavigationLink(isActive:)`，确保回到上一页。
    var onClose: (() -> Void)? = nil

    private var isLangZh: Bool {
        !AppLanguageManager.shared.usesEnglish
    }

    var body: some View {
        GeometryReader { pageProxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if controller.isCompleted {
                    completionView
                } else {
                    VStack(spacing: 0) {
                        topBar
                            .padding(.horizontal, 20)
                            .padding(.top, 8)

                        guideImageArea
                            .frame(width: pageProxy.size.width)
                            .frame(maxHeight: .infinity)

                        bottomCard
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)

                        Text(L10n.t("请跟随引导完成操作", "Please follow the guide to complete the operation"))
                            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                            .foregroundStyle(.white)
                            .padding(.bottom, 24)
                    }
                    .frame(width: pageProxy.size.width, height: pageProxy.size.height)
                }

                if let toastMessage = controller.toastMessage {
                    VStack {
                        Spacer()
                        Text(toastMessage)
                            .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.75))
                            .clipShape(Capsule())
                            .padding(.bottom, 120)
                    }
                    .transition(.opacity)
                }

                if controller.isLoading {
                    ProgressView()
                        .tint(.white)
                }
            }
            // 远端图片尺寸不能反向撑大根布局；所有非图片 UI 始终保持屏幕宽度。
            .frame(width: pageProxy.size.width, height: pageProxy.size.height)
            .clipped()
        }
        .background(Color.black.ignoresSafeArea())
        .compatibleNavigationContainerBackground(Color.black)
        .navigationControllerBackground(.black)
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .preferredColorScheme(.dark)
        .onAppear {
            controller.start(ble: ble, modelName: modelName, token: token)
        }
        .onDisappear {
            controller.stop()
        }
    }

    private func closeGuide() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                controller.skipCurrentStep()
            } label: {
                Text(L10n.t("跳过", "Skip"))
                    .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(minWidth: 60, minHeight: 40)
                    .padding(.horizontal, 4)
                    .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(min(controller.stepIndex + 1, controller.totalSteps))/\(controller.totalSteps)")
                .font(AppTheme.notoSansSC(size: 17, weight: .medium))
                .foregroundStyle(.white)

            Spacer()

            Button {
                closeGuide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var guideImageArea: some View {
        GeometryReader { imageProxy in
            ZStack(alignment: .topLeading) {
                Group {
                    if controller.isLoading {
                        // 引导接口完成前保留布局空间，只显示页面中央加载圈。
                        Color.clear
                    } else if let item = controller.currentItem,
                              let url = MediaURLResolver.url(for: item.image) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            case .failure:
                                Image(currentStepImageName)
                                    .resizable()
                                    .scaledToFit()
                            case .empty:
                                ProgressView()
                                    .tint(.white)
                            @unknown default:
                                Image(currentStepImageName)
                                    .resizable()
                                    .scaledToFit()
                            }
                        }
                    } else {
                        Image(currentStepImageName)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: imageProxy.size.width, height: imageProxy.size.height)
                .clipped()
                // 安卓引导图自带触控区标记，不再叠两个蓝圆。
            }
            .frame(width: imageProxy.size.width, height: imageProxy.size.height)
            .clipped()
        }
        .padding(.top, 20)
    }

    private var bottomCard: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image("android_guide_hand")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)

                    Text(actionTitle)
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(.black)

                    if controller.stepIndex == 7 {
                        // Android step 8 semantics: pause playback. Its current
                        // `new_icon17` bitmap is a stop square, so render the
                        // intended pause glyph instead of copying that bad asset.
                        Image(systemName: "pause.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 18, height: 18)
                    } else if let icon = stepIconName {
                        Image(icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                    }
                }

                Text(actionType)
                    .font(AppTheme.notoSansSC(size: 30, weight: .bold))
                    .foregroundStyle(.black)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
            .background(Color(red: 0.82, green: 0.92, blue: 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            if shouldShowVolumeTips {
                volumeTips
            }

            if shouldShowCaptureTip {
                captureTip
            }
        }
    }

    private var volumeTips: some View {
        VStack(spacing: 12) {
            tipRow(
                icon: "android_guide_volume_up",
                text: L10n.t("向前滑动：音量+", "Swipe forward: Volume +"),
                trailing: "android_guide_right_arrows"
            )
            tipRow(
                icon: "android_guide_volume_down",
                text: L10n.t("向后滑动：音量-", "Swipe backward: Volume -"),
                trailing: "android_guide_left_arrows"
            )
        }
        .padding(16)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var captureTip: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Image("android_guide_notice")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .frame(width: 32, height: 32)
                    .background(Color(red: 0.65, green: 0.75, blue: 0.82))
                    .clipShape(Circle())

                Text(captureTipText)
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(.white)

                Spacer(minLength: 4)
            }
            .padding(3)
            .background(Color.black)
            .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
        .background(Color(red: 0.65, green: 0.75, blue: 0.82))
        .clipShape(Capsule())
    }

    private func tipRow(icon: String, text: String, trailing: String) -> some View {
        HStack(spacing: 8) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .frame(width: 32, height: 32)
                .background(Color(red: 0.65, green: 0.75, blue: 0.82))
                .clipShape(Circle())

            Text(text)
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(.white)
            Spacer()
            Image(trailing)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }

    private var actionTitle: String {
        let zh = [
            "拍摄照片", "开始录像", "结束录像", "播放音乐", "调节音量",
            "下一首", "上一首", "暂停播放", "唤起AI语音助手"
        ]
        let en = [
            "Take Photo", "Start Recording", "End Recording", "Play Music", "Adjust Volume",
            "Next Track", "Previous Track", "Pause Playback", "Wake AI Voice Assistant"
        ]
        guard zh.indices.contains(controller.stepIndex) else { return "" }
        return isLangZh ? zh[controller.stepIndex] : en[controller.stepIndex]
    }

    private var actionType: String {
        let zh = [
            "单击拍摄按钮", "长按拍摄按钮", "录像状态\n单击拍摄按钮", "单击触控板", "前后滑动触控板",
            "双击触控板", "三击触控板", "单击触控板", "长按触控板"
        ]
        let en = [
            "Press Capture Button", "Press and Hold Capture Button", "Recording Mode\nPress Capture Button", "Tap Touchpad", "Swipe Touchpad Forward or Back",
            "Double-Tap Touchpad", "Triple-Tap Touchpad", "Tap Touchpad", "Press and Hold Touchpad"
        ]
        guard zh.indices.contains(controller.stepIndex) else { return "" }
        return isLangZh ? zh[controller.stepIndex] : en[controller.stepIndex]
    }

    private var shouldShowVolumeTips: Bool {
        guard let title = controller.currentItem?.title else { return false }
        return title.contains("音量")
    }

    private var shouldShowCaptureTip: Bool {
        controller.stepIndex == 0 || controller.stepIndex == 1
    }

    private var captureTipText: String {
        if controller.stepIndex == 1 {
            return L10n.t("录像时，眼镜外侧指示灯将会常亮", "The outer LED stays on while recording")
        }
        return L10n.t("拍照时，眼镜外侧指示灯将闪烁一次", "The outer LED flashes once when taking a photo")
    }

    private var stepIconName: String? {
        switch controller.stepIndex {
        case 0: return "android_guide_photo"
        case 1, 2: return "android_guide_video"
        case 3: return "android_guide_play"
        case 4: return "android_guide_volume"
        case 5: return "android_guide_next"
        case 6: return "android_guide_previous"
        case 7: return nil
        case 8: return "android_guide_ai"
        default: return nil
        }
    }

    private var currentStepImageName: String {
        switch controller.stepIndex {
        case 0: return "android_guide_glasses_photo"
        case 1, 2: return "android_guide_glasses_video"
        default: return "android_guide_glasses_default"
        }
    }

    private var completionView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 150)

            Image("android_guide_complete_glasses")
                .resizable()
                .scaledToFit()
                .frame(width: 342, height: 105)

            Text(L10n.t("恭喜你完成新手引导", "Newbie guide complete"))
                .font(AppTheme.notoSansSC(size: 24, weight: .bold))
                .foregroundStyle(Color(red: 0.33, green: 0.87, blue: 0.96))
                .padding(.top, 45)

            Text(L10n.t("你可以随时在“APP首页-新手引导”中重新开始", "You can restart anytime from Home - Newbie Guide"))
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.top, 20)

            Button(L10n.t("开始使用眼镜", "Start Using Glasses")) {
                closeGuide()
            }
            .font(AppTheme.notoSansSC(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 276, height: 48)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
            .padding(.top, 94)

            Spacer()

            Button(L10n.t("再看一遍", "View Again")) {
                controller.restart()
            }
            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
            .foregroundStyle(.white)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    CompatibleNavigationStack {
        NewbieGuideView(
            ble: AstraA1BleManager(),
            modelName: "G5T71",
            token: nil,
            onClose: {}
        )
    }
}
