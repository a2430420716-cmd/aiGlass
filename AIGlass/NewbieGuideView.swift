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
    private var guideSessionID = UUID()
    private var sessionStartedAt = Date.distantFuture
    private var sessionActive = false
    private var gen1TargetID: UUID?
    private var gen1StepState = Gen1GuideStepState()
    private var guideDataTask: Task<Void, Never>?
    private var waitDiagnosticTask: Task<Void, Never>?
    private var audioObservers: [AnyCancellable] = []

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
        if sessionActive { stop() }
        self.ble = ble
        guard ble.isDeviceAvailable else {
            isLoading = false
            showToast(L10n.t("请先连接已绑定的眼镜", "Please connect your bound glasses first"))
            return
        }
        guideSessionID = UUID()
        let sessionID = guideSessionID
        sessionStartedAt = Date()
        sessionActive = true
        gen1TargetID = ble.deviceGeneration == .gen1G5K61
            ? ble.deviceBluetoothIdentifier.flatMap(UUID.init(uuidString:)) : nil
        // 进入页面即锁定加载态；Task 真正开始前也不能闪出默认眼镜图。
        isLoading = true
        if let gen1TargetID {
            ble.gen1GuideEventSessionID = sessionID
            ble.gen1GuideEventTargetID = gen1TargetID
            ble.gen1GuideEventHandler = { [weak self] source, capturedAt, step, result in
                guard let self, self.guideSessionID == sessionID else { return }
                self.handleGen1GuideAck(source: source, capturedAt: capturedAt, step: step, result: result)
            }
            ble.gen1GuideMediaHandler = { [weak self] source, capturedAt, command in
                guard let self, self.guideSessionID == sessionID else { return }
                self.handleGen1Media(source: source, capturedAt: capturedAt, command: command)
            }
        } else {
            ble.guideEventHandler = { [weak self] eventType in
                Task { @MainActor in
                    guard let self, self.sessionActive, self.guideSessionID == sessionID else { return }
                    self.handleGuideEvent(eventType)
                }
            }
        }
        logGuide("引导开始", detail: "model=\(modelName)")
        observeGuideAudio()
        ensureGuideData()
        saveCurrentStep()
        enterGuideMode()
        guideDataTask = Task { await loadGuideData(modelName: modelName, token: token, sessionID: sessionID) }
    }

    func stop() {
        logGuide("引导退出")
        let ownsSession = gen1TargetID == nil || ble?.gen1GuideEventSessionID == guideSessionID
        sessionActive = false
        guideDataTask?.cancel()
        guideDataTask = nil
        waitDiagnosticTask?.cancel()
        waitDiagnosticTask = nil
        audioObservers.removeAll()
        gen1StepState.waitForStep(0)
        stopGuideMusic()
        exitGuideMode()
        if ownsSession { UserDefaults.standard.set(0, forKey: stepStorageKey) }
        if gen1TargetID != nil {
            if ble?.gen1GuideEventSessionID == guideSessionID {
                ble?.gen1GuideEventHandler = nil
                ble?.gen1GuideMediaHandler = nil
                ble?.gen1GuideEventTargetID = nil
                ble?.gen1GuideEventSessionID = nil
            }
        } else { ble?.guideEventHandler = nil }
        ble = nil
    }

    func skipCurrentStep() {
        logGuide("引导手动跳过")
        print("[NewbieGuide] skip step=\(stepIndex + 1)")
        advanceStep(reason: "user_skip")
    }

    func restart() {
        guard sessionActive, ble?.isDeviceAvailable == true else { return }
        if gen1TargetID != nil, !isCurrentGen1GuideSession { logGuide("引导重启忽略", detail: "reason=target_or_session_changed"); return }
        sessionStartedAt = Date()
        logGuide("引导重新开始")
        isCompleted = false
        stepIndex = 0
        lastEventType = -1
        lastEventTime = .distantPast
        saveCurrentStep()
        enterGuideMode()
        updateGuideMusicForStep()
    }

    private func loadGuideData(modelName: String, token: String?, sessionID: UUID) async {
        guard ownsGuideDataRequest(sessionID), !Task.isCancelled else { return }
        isLoading = true
        defer { if ownsGuideDataRequest(sessionID) { isLoading = false } }

        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ensureGuideData()
            return
        }

        do {
            let items = try await DeviceService.fetchDeviceGuide(modelName: name, token: token)
            guard ownsGuideDataRequest(sessionID), !Task.isCancelled else {
                logGuide("引导内容响应忽略", detail: "reason=page_or_session_changed")
                return
            }
            if items.count >= expectedEvents.count {
                guideItems = items
            } else {
                ensureGuideData()
            }
        } catch {
            guard ownsGuideDataRequest(sessionID), !Task.isCancelled else { return }
            logGuide("引导内容加载失败", detail: "error=\(error.localizedDescription)")
            print("[NewbieGuide] load guide failed: \(error.localizedDescription)")
            ensureGuideData()
        }
        saveCurrentStep()
    }

    private func ownsGuideDataRequest(_ sessionID: UUID) -> Bool {
        sessionActive && guideSessionID == sessionID
            && (gen1TargetID == nil || ble?.gen1GuideEventSessionID == sessionID)
    }

    private func ensureGuideData() {
        if guideItems.count < expectedEvents.count {
            guideItems = DeviceGuideItem.newbieGuideDefaults
        }
    }

    private func enterGuideMode() {
        guard let ble, ble.isDeviceAvailable else {
            showToast(L10n.t("设备未连接", "Not connected"))
            return
        }
        if gen1TargetID != nil {
            guard isCurrentGen1GuideSession else { logGuide("引导开启忽略", detail: "reason=target_or_session_changed"); return }
            gen1StepState.waitForStep(stepIndex + 1)
        }
        guideModeEnabled = ble.deviceGeneration == .gen1G5K61
            ? ble.setGuideStep(stepIndex + 1)
            : ble.setGuideModeEnabled(true)
        if !guideModeEnabled {
            showToast(L10n.t("设备未连接", "Not connected"))
        }
        logGuide("引导模式请求", detail: "queued=\(guideModeEnabled); queued_is_not_device_ack")
        armWaitDiagnostic()
    }

    private func exitGuideMode() {
        guard guideModeEnabled else { return }
        if gen1TargetID != nil {
            if isCurrentGuideTarget, ble?.gen1GuideEventSessionID == guideSessionID {
                let sent = ble?.setGuideStep(0) == true
                logGuide("引导退出请求", detail: "queued=\(sent)")
            } else { logGuide("引导退出指令未发送", detail: "reason=target_or_session_changed") }
        } else {
            _ = ble?.setGuideModeEnabled(false)
        }
        guideModeEnabled = false
    }

    private func handleGuideEvent(_ eventType: UInt8) {
        guard ble?.isDeviceAvailable == true, !isCompleted,
              ble?.deviceGeneration != .gen1G5K61 else { return }

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
        advanceStep(reason: "guide_event")
    }

    /// 一代只上报当前步骤完成状态，不能按二代触控事件解释。
    private func handleGen1GuideAck(source: UUID, capturedAt: Date, step: Int, result: Int) {
        let evidence = "source=\(source) receivedStep=\(step) result=\(result) callbackAt=\(capturedAt.timeIntervalSince1970)"
        if let reason = gen1EventRejection(source: source, capturedAt: capturedAt) {
            logGuide("引导完成回包忽略", detail: "\(evidence) reason=\(reason)")
            return
        }
        let decision = gen1StepState.receiveAcknowledgement(step: step, result: result)
        logGuide("引导完成回包处理", detail: "\(evidence) decision=\(decision)")
        if case .completed(let action) = decision {
            if let action { performGen1MediaAction(action) }
            advanceStep(reason: "gen1_step_ack")
        }
    }

    private func handleGen1Media(source: UUID, capturedAt: Date, command: UInt8) {
        let evidence = "source=\(source) command=\(String(format: "0x%02X", command)) callbackAt=\(capturedAt.timeIntervalSince1970)"
        if let reason = gen1EventRejection(source: source, capturedAt: capturedAt) {
            logGuide("引导媒体事件忽略", detail: "\(evidence) reason=\(reason)")
            return
        }
        let decision = gen1StepState.receiveMedia(command: command)
        logGuide("引导媒体事件处理", detail: "\(evidence) decision=\(decision); media_does_not_advance_step")
        if case .media(let action) = decision { performGen1MediaAction(action) }
    }

    private var isCurrentGuideTarget: Bool {
        guard let gen1TargetID, let ble else { return false }
        return ble.deviceGeneration == .gen1G5K61
            && ble.deviceBluetoothIdentifier == gen1TargetID.uuidString
            && ble.savedPeripheralUUIDString == gen1TargetID.uuidString
    }

    private var isCurrentGen1GuideSession: Bool {
        isCurrentGuideTarget && ble?.gen1GuideEventSessionID == guideSessionID
    }

    private func gen1EventRejection(source: UUID, capturedAt: Date) -> String? {
        if !sessionActive { return "page_inactive" }
        if capturedAt < sessionStartedAt { return "callback_before_session_started" }
        if source != gen1TargetID || !isCurrentGuideTarget { return "target_changed" }
        if ble?.gen1GuideEventSessionID != guideSessionID { return "session_replaced" }
        if ble?.isDeviceAvailable != true { return "device_unavailable" }
        if !guideModeEnabled { return "guide_not_enabled" }
        if isCompleted { return "guide_already_completed" }
        return nil
    }

    private func performGen1MediaAction(_ action: Gen1GuideStepState.MediaAction) {
        switch action {
        case .play: playGuideMusic(index: 1, restart: true)
        case .pause: pauseGuideMusic()
        case .next: playGuideMusic(index: nextGuideMusicIndex(), restart: true)
        case .previous: playGuideMusic(index: previousGuideMusicIndex(), restart: true)
        }
    }

    private func advanceStep(reason: String) {
        guard sessionActive, !isCompleted, ble?.isDeviceAvailable == true else {
            logGuide("引导推进忽略", detail: "reason=inactive_completed_or_device_unavailable")
            return
        }
        if gen1TargetID != nil, !isCurrentGen1GuideSession { logGuide("引导推进忽略", detail: "reason=target_or_session_changed"); return }
        waitDiagnosticTask?.cancel()
        logGuide("引导步骤完成", detail: "reason=\(reason)")
        if stepIndex >= expectedEvents.count - 1 {
            isCompleted = true
            gen1StepState.waitForStep(0)
            UserDefaults.standard.set(0, forKey: stepStorageKey)
            exitGuideMode()
            stopGuideMusic()
            return
        }
        stepIndex += 1
        if ble?.deviceGeneration == .gen1G5K61, guideModeEnabled {
            gen1StepState.waitForStep(stepIndex + 1)
            let sent = ble?.setGuideStep(stepIndex + 1) == true
            logGuide("引导切换步骤", detail: "reason=\(reason) queued=\(sent); queued_is_not_device_ack")
            if !sent {
                showToast(L10n.t("引导步骤同步失败，请重试", "Couldn't sync the guide step. Try again."))
            }
        }
        saveCurrentStep()
        updateGuideMusicForStep()
        armWaitDiagnostic()
    }

    private func logGuide(_ title: String, detail: String = "") {
        DebugLogStore.logBLEEvent(title, detail: "session=\(guideSessionID) target=\(gen1TargetID?.uuidString ?? ble?.deviceBluetoothIdentifier ?? "nil") step=\(stepIndex + 1) waitingStep=\(gen1StepState.waitingStep) active=\(sessionActive) enabled=\(guideModeEnabled) completed=\(isCompleted) available=\(ble?.isDeviceAvailable == true) playerExists=\(guideMusicPlayer != nil) track=\(guideMusicIndex + 1) playing=\(guideMusicPlayer?.isPlaying == true) \(detail)")
    }

    private func armWaitDiagnostic() {
        waitDiagnosticTask?.cancel()
        guard gen1TargetID != nil, sessionActive, !isCompleted else { return }
        let sessionID = guideSessionID, step = stepIndex
        let started = ProcessInfo.processInfo.systemUptime
        waitDiagnosticTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, self.sessionActive, !self.isCompleted,
                      self.guideSessionID == sessionID, self.stepIndex == step else { return }
                self.logGuide("引导仍在等待完成回包", detail: "elapsed=\(Int(ProcessInfo.processInfo.systemUptime - started))s; no_automatic_step_advance\n\(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
            }
        }
    }

    private func observeGuideAudio() {
        let sessionID = guideSessionID
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            audioObservers.append(NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] note in
                guard let self, self.sessionActive, self.guideSessionID == sessionID else { return }
                let interruption = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let routeReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                self.logGuide("引导音频状态变化", detail: "notification=\(name.rawValue) interruption=\(interruption.map(String.init) ?? "nil") routeReason=\(routeReason.map(String.init) ?? "nil")\n\(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
            })
        }
    }

    private func saveCurrentStep() {
        guard ownsGuideDataRequest(guideSessionID) else { return }
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
        logGuide("引导音乐播放请求", detail: "requestedTrack=\(index + 1) restart=\(restart)")
        let targetIndex = max(0, min(index, guideMusicNames.count - 1))
        if !restart,
           guideMusicIndex == targetIndex,
           guideMusicPlayer?.isPlaying == true {
            return
        }

        if guideMusicIndex != targetIndex || guideMusicPlayer == nil || restart {
            releaseGuideMusicPlayer()
            guard let url = guideMusicURL(at: targetIndex) else {
                logGuide("引导音乐播放失败", detail: "reason=resource_missing resource=\(guideMusicNames[targetIndex])")
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
                logGuide("引导音乐播放失败", detail: "reason=audio_session_or_player_error error=\(error.localizedDescription)")
                print("[NewbieGuide] create music player failed: \(error.localizedDescription)")
                releaseGuideMusicPlayer()
                return
            }
        }

        guard let player = guideMusicPlayer else { return }
        if player.play() {
            logGuide("引导音乐播放结果", detail: "success=true\n\(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
            print("[NewbieGuide] music playing: index=\(targetIndex + 1)")
        } else {
            logGuide("引导音乐播放结果", detail: "success=false reason=player_play_returned_false\n\(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
            print("[NewbieGuide] start music failed: index=\(targetIndex + 1)")
        }
    }

    private func pauseGuideMusic() {
        logGuide("引导音乐暂停请求")
        guideMusicPlayer?.pause()
        logGuide("引导音乐暂停结果", detail: "playerPresent=\(guideMusicPlayer != nil); missing_player_is_not_pause_success")
        print("[NewbieGuide] music paused: index=\(guideMusicIndex + 1)")
    }

    private func stopGuideMusic() {
        logGuide("引导音乐停止")
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
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Image("android_guide_complete_glasses")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 342)
                        .frame(height: 105)

                    Text(L10n.t("恭喜你完成新手引导", "Newbie guide complete"))
                        .font(AppTheme.notoSansSC(size: 24, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.33, green: 0.87, blue: 0.96), Color(red: 0.65, green: 0.66, blue: 1.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 36)

                    Text(L10n.t("你可以随时在“APP首页-新手引导”中重新开始", "You can restart anytime from Home - Newbie Guide"))
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.top, 20)

                    Button(L10n.t("开始使用眼镜", "Start Using Glasses")) {
                        closeGuide()
                    }
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 276)
                    .frame(height: 48)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                    .padding(.top, max(32, proxy.size.height * 0.10))

                    Spacer(minLength: 32)

                    Button(L10n.t("再看一遍", "View Again")) {
                        controller.restart()
                    }
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(minHeight: 44)
                    .padding(.bottom, 20)
                }
                .padding(.horizontal, 16)
                .padding(.top, max(48, proxy.size.height * 0.20))
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
        }
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
