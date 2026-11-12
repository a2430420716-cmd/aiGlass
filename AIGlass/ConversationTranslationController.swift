@preconcurrency import AVFoundation
import Combine
import Foundation

struct ConversationTranslationMessage: Identifiable, Equatable {
    enum Side {
        case glasses
        case phone
    }

    let id: UUID
    let side: Side
    let sourceLanguage: String
    let targetLanguage: String
    var sourceText: String
    var translatedText: String
    var speechData: Data?
    var hasSpeech: Bool
}

/// 对话翻译控制器：对齐安卓 `ConversationTranslationActivity`。
@MainActor
final class ConversationTranslationController: ObservableObject {
    enum RecordingSide {
        case glasses
        case phone
    }

    @Published var glassesLanguage = "中文"
    @Published var phoneLanguage = "英文"
    @Published private(set) var messages: [ConversationTranslationMessage] = []
    @Published private(set) var glassesRecording = false
    @Published private(set) var glassesConnecting = false
    @Published private(set) var phoneRecording = false
    @Published private(set) var waitingPhoneSocketReady = false
    @Published private(set) var statusText = L10n.t("点击下方按钮开始录音", "Tap a button below to start recording")
    @Published var alertMessage: String?

    var glassesActive: Bool { glassesRecording || glassesConnecting }
    var phoneActive: Bool { phoneRecording || waitingPhoneSocketReady }

    private weak var ble: AstraA1BleManager?
    private var manager: RealtimeTranslationManager?
    private var token = ""
    private let microphoneCapture = TranslationMicrophoneCapture()
    private let glassesOpusDecoder = AIVoiceM4aConverter.StreamingOpusDecoder()
    private var glassesState = TranslationGlassesRecordingState()
    private var isActive = false
    private var permissionGeneration = 0
    private var loggedFirstGlassesPCM = false
    private var glassesOpusFrames = 0
    private var glassesDecodeErrors = 0
    private var glassesDroppedFrames = 0
    private var glassesAcceptedPCMBytes = 0
    private var glassesPCMStatistics = TranslationPCMStatistics()
    private var deferredGlassesSpeech = TranslationDeferredSpeechQueue()
    @Published private(set) var glassesStopping = false
    private var glassesStopTask: Task<Void, Never>?
    private var glassesStopState = TranslationGlassesStopState()
    private var glassesStopOperation: UUID?
    private var glassesDecodeTiming = TranslationAudioTiming()
    private var glassesQueueTiming = TranslationAudioTiming()
    private var glassesInputStartedAt: TimeInterval?
    private var socketReadyTask: Task<Void, Never>?
    private var bleStateSubscription: AnyCancellable?

    private var activeSide: RecordingSide?
    private var currentTurnSide: RecordingSide?
    private var currentMessageID: UUID?
    private var sourceSegments: [String] = []
    private var targetSegments: [String] = []
    private var latestTranscript = ""
    private var latestTranslation = ""
    private var lastBackendErrorMessage = ""

    private let conversationID = UUID()
    private var glassesStartTask: Task<Void, Never>?
    private var phoneAutoStopTask: Task<Void, Never>?
    private var processingStatusTask: Task<Void, Never>?

    private let phoneRecordMaxNs: UInt64 = 60_000_000_000
    private let glassesStartTimeoutNs: UInt64 = 3_000_000_000
    private let gen1GlassesStartTimeoutNs: UInt64 = 15_000_000_000
    private let processingFallbackNs: UInt64 = 8_000_000_000

    func start(ble: AstraA1BleManager, token: String?) {
        isActive = true
        self.ble = ble
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        logRecordingLifecycle("page appeared")
        // Android only disables local AI capture here. Sending an AI stop command
        // can race the translation start on the same device microphone.
        AIVoiceChatManager.shared.setVoiceChatCaptureEnabled(false)
        ble.translationVoiceNotifyHandler = { [weak self] command, packet in
            // Preserve START/DATA/END ordering on the BLE manager's MainActor.
            self?.handleGlassesNotify(command: command, packet: packet)
        }
        bleStateSubscription = ble.$connectionState.dropFirst().sink { [weak self] state in
            guard let self, self.isActive else { return }
            self.logRecordingLifecycle("BLE state published: \(state)")
            guard self.glassesState.hasSentCommand else { return }
            if case .ready = state { return }
            if self.glassesStopping {
                self.finishGlassesStream(reason: "BLE disconnected while draining", confirmed: false)
            } else {
                self.failGlassesStart(reason: "BLE disconnected")
            }
            self.statusText = L10n.t("请先连接眼镜", "Please connect glasses first")
        }
        statusText = L10n.t("点击下方按钮开始录音", "Tap a button below to start recording")
    }

    func stop() {
        logRecordingLifecycle("page disappearing")
        isActive = false
        permissionGeneration += 1
        bleStateSubscription?.cancel()
        bleStateSubscription = nil
        persistConversation()
        stopAllRecording(resetSocket: true)
        ble?.translationVoiceNotifyHandler = nil
        AIVoiceChatManager.shared.setVoiceChatCaptureEnabled(true)
    }

    func swapLanguages() {
        guard !glassesActive, !phoneActive else { return }
        (glassesLanguage, phoneLanguage) = (phoneLanguage, glassesLanguage)
    }

    func updateGlassesLanguage(_ language: String) {
        guard !glassesActive, !phoneActive else { return }
        glassesLanguage = language
        if sameLanguage(glassesLanguage, phoneLanguage) {
            phoneLanguage = TranslationLanguage.fallback(excluding: language)
        }
    }

    func updatePhoneLanguage(_ language: String) {
        guard !glassesActive, !phoneActive else { return }
        phoneLanguage = language
        if sameLanguage(glassesLanguage, phoneLanguage) {
            glassesLanguage = TranslationLanguage.fallback(excluding: language)
        }
    }

    func toggleGlassesRecording() {
        logRecordingLifecycle("glasses button tapped")
        permissionGeneration += 1
        guard isActive, !glassesStopping else { return }
        // 连接中再点一次：取消开麦。
        if glassesConnecting, !glassesRecording {
            deferredGlassesSpeech.cancel()
            glassesConnecting = false
            cancelSocketReadyTimeout()
            cancelGlassesStartTimeout()
            if glassesState.hasSentCommand { _ = ble?.stopTranslateRecording() }
            glassesState.reset()
            ble?.resetTranslateRecordingState()
            manager?.markLocalRecordingStopped(reason: "conversation glasses start cancelled")
            manager?.finish()
            manager?.close()
            activeSide = nil
            statusText = L10n.t("点击下方按钮开始录音", "Tap a button below to start recording")
            return
        }
        if glassesRecording {
            let sent = ble?.stopTranslateRecording() ?? false
            print("[ConversationTranslation] stop translate record sent=\(sent)")
            guard sent else {
                alertMessage = ble?.mediaActionAlertMessage ?? L10n.t("眼镜录音停止失败，请重试", "Failed to stop glasses recording. Try again.")
                return
            }
            if ble?.deviceGeneration == .gen1G5K61 {
                // Stop ACK is not END; keep the socket input and decoder alive for final DATA.
                glassesStopping = true
                glassesState.drain()
                statusText = L10n.t("正在结束录音…", "Finishing recording…")
                beginGlassesStopMonitor()
                return
            }
            glassesState.reset()
            manager?.markLocalRecordingStopped(reason: "conversation glasses manual stop")
            manager?.finish()
            glassesRecording = false
            enterProcessingStatus(reason: "glasses manual stop")
            releaseGlassesSpeech(reason: "Gen2 manual stop")
            return
        }
        if phoneActive {
            stopPhoneRecording()
        }
        guard ble?.isDeviceAvailable == true else {
            logRecordingLifecycle("glasses button rejected: bound device unavailable")
            alertMessage = L10n.t("请先连接已绑定的眼镜", "Please connect your bound glasses first")
            return
        }
        guard !token.isEmpty else {
            alertMessage = L10n.t("未登录，无法使用对话翻译", "Not signed in, cannot use conversation translation")
            return
        }
        activeSide = .glasses
        beginTranslationTurn()
        glassesState.begin()
        glassesConnecting = true
        statusText = L10n.t("正在连接翻译服务…", "Connecting to translation service…")
        connectManager(
            source: glassesLanguage,
            target: phoneLanguage
        )
    }

    func togglePhoneRecording() {
        logRecordingLifecycle("phone button tapped")
        guard isActive else { return }
        permissionGeneration += 1
        let permissionRequest = permissionGeneration
        if phoneActive {
            stopPhoneRecording()
            return
        }
        if glassesActive {
            deferredGlassesSpeech.cancel()
            if glassesState.hasSentCommand { _ = ble?.stopTranslateRecording() }
            glassesState.reset()
            glassesStopTask?.cancel()
            glassesStopTask = nil
            glassesStopState.reset()
            glassesStopOperation = nil
            glassesStopping = false
            ble?.resetTranslateRecordingState()
            cancelSocketReadyTimeout()
            cancelGlassesStartTimeout()
            manager?.markLocalRecordingStopped(reason: "conversation switch from glasses to phone")
            manager?.finish()
            glassesConnecting = false
            glassesRecording = false
        }
        Task {
            let granted = await requestMicrophonePermission()
            guard isActive, permissionGeneration == permissionRequest else { return }
            logRecordingLifecycle("phone microphone permission granted=\(granted)")
            guard granted else {
                alertMessage = L10n.t("请开启麦克风权限后重试", "Enable microphone access and try again")
                statusText = L10n.t("请开启麦克风权限后重试", "Enable microphone access and try again")
                return
            }
            startPhoneRecording()
        }
    }

    func replay(_ message: ConversationTranslationMessage) {
        guard !glassesActive, !phoneActive else {
            alertMessage = L10n.t("请先停止录音再播放译文", "Stop recording before playing translation audio.")
            return
        }
        guard let data = message.speechData, !data.isEmpty else { return }
        let played: Bool
        if message.side == .glasses {
            played = manager?.replaySpeechOnPhone(data) ?? false
            statusText = L10n.t("正在播放译文语音…", "Playing translation audio…")
        } else {
            played = manager?.replaySpeechOnGlasses(data) ?? false
        }
        if !played { statusText = L10n.t("眼镜音频不可用", "Glasses audio unavailable") }
    }

    // MARK: - Turn lifecycle

    private func logRecordingLifecycle(_ event: String) {
        DebugLogStore.logTranslation("conversation recording lifecycle", detail:
            "event=\(event) active=\(isActive) side=\(String(describing: activeSide)) glassesPhase=\(glassesState.phase) phoneRecording=\(phoneRecording) phoneWaiting=\(waitingPhoneSocketReady) ble={\(ble?.connectionAvailabilityDiagnosticDetail ?? "missing_manager")}")
    }

    private func beginTranslationTurn() {
        deferredGlassesSpeech.cancel()
        if activeSide == .glasses { deferredGlassesSpeech.begin() }
        glassesStopTask?.cancel()
        glassesStopTask = nil
        glassesStopState.reset()
        glassesStopOperation = nil
        glassesStopping = false
        glassesOpusDecoder.reset()
        loggedFirstGlassesPCM = false
        glassesOpusFrames = 0
        glassesDecodeErrors = 0
        glassesDroppedFrames = 0
        glassesAcceptedPCMBytes = 0
        glassesPCMStatistics = TranslationPCMStatistics()
        glassesDecodeTiming = TranslationAudioTiming()
        glassesQueueTiming = TranslationAudioTiming()
        glassesInputStartedAt = nil
        cancelProcessingStatusFallback()
        manager?.resetSpeechPlaybackForTurn()
        latestTranscript = ""
        latestTranslation = ""
        lastBackendErrorMessage = ""
        currentMessageID = nil
        sourceSegments.removeAll()
        targetSegments.removeAll()
        currentTurnSide = activeSide
    }

    private func connectManager(source: String, target: String) {
        let next = RealtimeTranslationManager(callback: self)
        manager?.close()
        manager = next
        next.setSpeechPlaybackEnabled(true)
        next.setAutoPlayIncomingSpeech(false)
        next.connect(
            sourceLanguage: TranslationLanguage.code(forDisplayName: source),
            targetLanguage: TranslationLanguage.code(forDisplayName: target),
            token: token
        )
        scheduleSocketReadyTimeout()
    }

    private func startGlassesCommand() {
        guard isActive, glassesConnecting, glassesState.shouldSendStart else { return }
        guard ble?.isDeviceAvailable == true else {
            logRecordingLifecycle("glasses START rejected: bound device unavailable")
            failGlassesStart(reason: "Bound glasses unavailable before START")
            alertMessage = L10n.t("请先连接已绑定的眼镜", "Please connect your bound glasses first")
            return
        }
        print("[ConversationTranslation] glasses start requested generation=\(ble?.deviceGeneration.rawValue ?? "unknown")")
        guard ble?.startTranslateRecording() == true else {
            glassesState.reset()
            activeSide = nil
            glassesConnecting = false
            statusText = L10n.t("眼镜录音开启失败", "Failed to start glasses recording")
            alertMessage = ble?.mediaActionAlertMessage ?? statusText
            return
        }
        glassesState.commandSent()
        scheduleGlassesStartTimeout()
        statusText = L10n.t("正在开启眼镜麦克风…", "Enabling glasses mic…")
    }

    private func startPhoneRecording() {
        logRecordingLifecycle("phone service connection requested")
        guard !token.isEmpty else {
            alertMessage = L10n.t("未登录，无法使用对话翻译", "Not signed in, cannot use conversation translation")
            return
        }
        activeSide = .phone
        beginTranslationTurn()
        waitingPhoneSocketReady = true
        statusText = L10n.t("正在连接翻译服务…", "Connecting to translation service…")
        // 手机侧：源/目标语言对调（安卓 connect(target, source)）。
        connectManager(source: phoneLanguage, target: glassesLanguage)
    }

    private func beginPhoneAudioRecord() {
        logRecordingLifecycle("phone microphone start requested")
        guard manager?.markLocalRecordingStarted() == true else {
            waitingPhoneSocketReady = false
            phoneRecording = false
            statusText = L10n.t("正在连接翻译服务…", "Connecting to translation service…")
            print("[ConversationTranslation] phone record start blocked by input gate")
            return
        }
        waitingPhoneSocketReady = false
        phoneRecording = true
        statusText = L10n.t("正在录音…", "Recording…")
        schedulePhoneAutoStop()
        do {
            manager?.setPhoneMicrophoneCaptureEnabled(true)
            let recordingManager = manager
            try microphoneCapture.start(label: "conversation phone", receive: { [weak self] pcm in
                guard let self, self.isActive, self.phoneRecording,
                      self.manager === recordingManager else { return false }
                return recordingManager?.sendPCM(pcm) ?? false
            }, failure: { [weak self] error in
                guard let self, self.isActive, self.phoneRecording,
                      self.manager === recordingManager else { return }
                self.stopPhoneRecording()
                self.alertMessage = error.localizedDescription
                self.statusText = error.localizedDescription
            })
        } catch {
            phoneRecording = false
            stopPhoneAudio()
            manager?.markLocalRecordingStopped(reason: "phone audio start failed")
            alertMessage = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    private func stopPhoneRecording() {
        guard phoneRecording || waitingPhoneSocketReady else { return }
        cancelSocketReadyTimeout()
        phoneAutoStopTask?.cancel()
        phoneAutoStopTask = nil
        waitingPhoneSocketReady = false
        phoneRecording = false
        stopPhoneAudio()
        manager?.markLocalRecordingStopped(reason: "conversation phone stop")
        manager?.finish()
        enterProcessingStatus(reason: "phone stop")
    }

    private func stopPhoneAudio() {
        manager?.setPhoneMicrophoneCaptureEnabled(false)
        microphoneCapture.stop()
    }

    private func stopAllRecording(resetSocket: Bool) {
        deferredGlassesSpeech.cancel()
        if glassesState.hasSentCommand { logGlassesAudio("stop all") }
        cancelSocketReadyTimeout()
        glassesStopState.reset()
        glassesStopOperation = nil
        glassesStopTask?.cancel()
        glassesStopTask = nil
        glassesStopping = false
        glassesOpusDecoder.close()
        glassesConnecting = false
        waitingPhoneSocketReady = false
        cancelProcessingStatusFallback()
        cancelGlassesStartTimeout()
        phoneAutoStopTask?.cancel()
        phoneAutoStopTask = nil
        // A selected side or pending WebSocket never establishes mic ownership.
        // Do not send STOP after a rejected start, service timeout or phone-only turn.
        if glassesState.hasSentCommand {
            manager?.markLocalRecordingStopped(reason: "conversation stopAll glasses")
            _ = ble?.stopTranslateRecording()
            ble?.resetTranslateRecordingState()
        }
        if phoneRecording {
            manager?.markLocalRecordingStopped(reason: "conversation stopAll phone")
            phoneRecording = false
            stopPhoneAudio()
        }
        glassesRecording = false
        glassesState.reset()
        if resetSocket {
            manager?.close()
            manager = nil
        }
        activeSide = nil
    }

    // MARK: - Glasses BLE

    private func handleGlassesNotify(command: String, packet: Data) {
        guard isActive, activeSide == .glasses, glassesState.hasSentCommand else { return }
        switch command {
        case "trslatests":
            guard let status = AstraA1BleProtocol.parseTranslateRecordStatus(packet) else {
                print("[ConversationTranslation] invalid translate status bytes=\(packet.count)")
                return
            }
            print("[ConversationTranslation] translate status=\(status) phase=\(glassesState.phase)")
            logGlassesAudio("status=\(status)")
            switch status {
            case 1:
                _ = confirmGlassesStarted(reason: "device START", resetDecoder: true)
            case 0, 2:
                let failedToStart = glassesState.isWaitingForDevice
                    || (ble?.deviceGeneration == .gen1G5K61 && status == 2)
                finishGlassesStream(reason: "translate status=\(status)")
                if failedToStart {
                    cancelProcessingStatusFallback()
                    statusText = L10n.t("眼镜录音开启失败", "Failed to start glasses recording")
                }
            case 3:
                failGlassesStart(reason: "device rejected translation START")
            default:
                break
            }
        case "trslatedat":
            // A valid decoded audio frame is stronger start evidence than an ACK.
            // Gen1 still requires its typed AE3D START; its DATA comes via gen1trdat0.
            guard ble?.deviceGeneration == .gen2,
                  glassesState.isWaitingForDevice || glassesState.acceptsAudio else { return }
            let frames = AstraA1BleProtocol.parseTranslateRecordFrames(packet)
            guard !frames.isEmpty else { return }
            var pcm = Data()
            for frame in frames {
                if let chunk = decodeGlassesOpus(frame) { pcm.append(chunk) }
            }
            guard !pcm.isEmpty else { return }
            if glassesState.isWaitingForDevice {
                guard confirmGlassesStarted(reason: "valid Opus DATA before ACK", resetDecoder: false) else { return }
            }
            sendGlassesPCM(pcm)
        case "gen1trsak":
            guard glassesStopping, packet == Data([0]) else { return }
            glassesStopState.acknowledge()
            logGlassesAudio("STOP acknowledged; awaiting audio END")
        case "gen1trsb0":
            guard glassesStopping else { return }
            logGlassesAudio("STOP rejected as busy; awaiting END within original deadline")
        case "gen1trdat0":
            guard !packet.isEmpty else { return }
            guard isGlassesStreamingActive() else {
                glassesDroppedFrames += 1
                if glassesDroppedFrames == 1 { logGlassesAudio("DATA before input active") }
                return
            }
            if glassesStopping { glassesStopState.receivedData(now: ProcessInfo.processInfo.systemUptime) }
            if let pcm = decodeGlassesOpus(packet) { sendGlassesPCM(pcm) }
        default:
            break
        }
    }

    @discardableResult
    private func confirmGlassesStarted(reason: String, resetDecoder: Bool) -> Bool {
        if glassesState.acceptsAudio { return true }
        guard glassesState.isWaitingForDevice else { return false }
        guard manager?.markLocalRecordingStarted() == true else {
            failGlassesStart(reason: "input gate closed after \(reason)")
            return false
        }
        guard glassesState.confirmStarted() else { return false }
        cancelGlassesStartTimeout()
        glassesConnecting = false
        glassesRecording = true
        glassesInputStartedAt = ProcessInfo.processInfo.systemUptime
        if resetDecoder { glassesOpusDecoder.reset() }
        statusText = L10n.t("正在录音…", "Recording…")
        logGlassesAudio("input confirmed reason=\(reason)")
        print("[ConversationTranslation] glasses input started reason=\(reason)")
        return true
    }

    private func sendGlassesPCM(_ pcm: Data) {
        guard isGlassesStreamingActive() else { return }
        let queuedAt = ProcessInfo.processInfo.systemUptime
        let sent = manager?.sendPCM(pcm) ?? false
        glassesQueueTiming.record(at: queuedAt, delay: ProcessInfo.processInfo.systemUptime - queuedAt)
        if sent {
            glassesAcceptedPCMBytes += pcm.count
        } else {
            glassesDroppedFrames += 1
            if glassesDroppedFrames == 1 { logGlassesAudio("PCM rejected by socket gate") }
        }
        if sent, !loggedFirstGlassesPCM {
            loggedFirstGlassesPCM = true
            logGlassesAudio("first PCM queued")
            print("[ConversationTranslation] first glasses PCM accepted bytes=\(pcm.count)")
        }
    }

    private func decodeGlassesOpus(_ packet: Data) -> Data? {
        glassesOpusFrames += 1
        let decodeAt = ProcessInfo.processInfo.systemUptime
        do {
            let pcm = try glassesOpusDecoder.decode(packet)
            guard !pcm.isEmpty else { throw AIVoiceM4aConverter.ConverterError.decodeFailed }
            glassesDecodeTiming.record(at: decodeAt, delay: ProcessInfo.processInfo.systemUptime - decodeAt)
            glassesPCMStatistics.append(pcm)
            if glassesOpusFrames == 1 || glassesOpusFrames.isMultiple(of: 100) {
                logGlassesAudio("Opus decoded opusBytes=\(packet.count)")
            }
            return pcm
        } catch {
            glassesDecodeTiming.record(at: decodeAt, delay: ProcessInfo.processInfo.systemUptime - decodeAt)
            glassesDecodeErrors += 1
            if glassesDecodeErrors == 1 || glassesDecodeErrors.isMultiple(of: 100) {
                let detail = error as NSError
                logGlassesAudio("Opus failed opusBytes=\(packet.count) domain=\(detail.domain) code=\(detail.code) error=\(error.localizedDescription)")
            }
            return nil
        }
    }

    private func logGlassesAudio(_ reason: String) {
        let wallMs = glassesInputStartedAt.map { Int(max(0, ProcessInfo.processInfo.systemUptime - $0) * 1000) } ?? 0
        DebugLogStore.logBLEEvent("conversation audio", detail: "reason=\(reason) generation=\(ble?.deviceGeneration.rawValue ?? "unknown") phase=\(glassesState.phase) opusFrames=\(glassesOpusFrames) decodeErrors=\(glassesDecodeErrors) droppedFrames=\(glassesDroppedFrames) acceptedPCMBytes=\(glassesAcceptedPCMBytes) canSend=\(manager?.canSendAudio() ?? false) wallMs=\(wallMs) stopACK=\(glassesStopState.acknowledged) stopRetried=\(glassesStopState.retried) decode={\(glassesDecodeTiming.detail)} queueAccept={\(glassesQueueTiming.detail)} \(glassesPCMStatistics.detail)")
    }

    private func failGlassesStart(reason: String) {
        deferredGlassesSpeech.cancel()
        logGlassesAudio("failed: \(reason)")
        DebugLogStore.logBLEEvent("translation audio START failed", detail: "reason=\(reason) phase=\(glassesState.phase) generation=\(ble?.deviceGeneration.rawValue ?? "unknown")")
        print("[ConversationTranslation] glasses start failed reason=\(reason) phase=\(glassesState.phase)")
        // Match Android: only Gen1 sends a failure-stop. For Gen2, a missing
        // start ACK must not itself inject trslate000=0 after three seconds.
        if ble?.deviceGeneration == .gen1G5K61, glassesState.hasSentCommand {
            _ = ble?.stopTranslateRecording()
        }
        ble?.resetTranslateRecordingState()
        glassesState.reset()
        cancelSocketReadyTimeout()
        cancelGlassesStartTimeout()
        glassesStopTask?.cancel()
        glassesStopTask = nil
        glassesStopState.reset()
        glassesStopOperation = nil
        glassesStopping = false
        glassesOpusDecoder.close()
        manager?.markLocalRecordingStopped(reason: reason)
        manager?.finish()
        manager?.close()
        glassesConnecting = false
        glassesRecording = false
        statusText = L10n.t("眼镜录音开启失败", "Failed to start glasses recording")
    }

    private func finishGlassesStream(reason: String, confirmed: Bool = true) {
        let recorded = glassesRecording
        logGlassesAudio("finished: \(reason)")
        glassesState.reset()
        ble?.resetTranslateRecordingState()
        glassesStopState.reset()
        glassesStopOperation = nil
        cancelGlassesStartTimeout()
        glassesStopTask?.cancel()
        glassesStopTask = nil
        glassesStopping = false
        glassesConnecting = false
        glassesRecording = false
        glassesOpusDecoder.close()
        manager?.markLocalRecordingStopped(reason: "conversation \(reason)")
        manager?.finish()
        enterProcessingStatus(reason: reason)
        if !confirmed {
            // The device may still be capturing. Do not auto-play TTS into its mic.
            deferredGlassesSpeech.cancel()
            alertMessage = L10n.t("尚未确认眼镜录音结束，请稍后重试", "Could not confirm that glasses recording ended. Please try again shortly.")
        } else if recorded, isActive {
            releaseGlassesSpeech(reason: reason)
        } else {
            deferredGlassesSpeech.cancel()
        }
    }

    private func releaseGlassesSpeech(reason: String) {
        // Never create a playback buffer (and its echo gate) while mic PCM is live.
        guard isActive, !glassesActive, !phoneActive else { return }
        let overflowed = deferredGlassesSpeech.overflowed
        let chunks = deferredGlassesSpeech.release()
        let bytes = chunks.reduce(0) { $0 + $1.count }
        DebugLogStore.logTranslation("glasses speech released", detail: "reason=\(reason) chunks=\(chunks.count) bytes=\(bytes) overflowed=\(overflowed) opusFrames=\(glassesOpusFrames) droppedBatches=\(glassesDroppedFrames) acceptedPCMBytes=\(glassesAcceptedPCMBytes)")
        if overflowed {
            // The full speech remains available on the message's replay button.
            alertMessage = L10n.t("译文语音较长，自动播报仅包含前一部分；录音上传不受影响，可点击消息播放完整译文", "Translation audio is long. Automatic playback contains the first part; recording upload is unaffected. Tap the message to replay the full translation.")
        }
        guard !chunks.isEmpty else { return }
        cancelProcessingStatusFallback()
        for data in chunks { manager?.playSpeechOnPhone(data) }
        statusText = L10n.t("正在播放译文语音…", "Playing translation audio…")
    }

    private func beginGlassesStopMonitor() {
        glassesStopTask?.cancel()
        let operation = UUID()
        let targetID = ble?.deviceBluetoothIdentifier
        glassesStopOperation = operation
        glassesStopState.begin(now: ProcessInfo.processInfo.systemUptime)
        logGlassesAudio("STOP monitor started")
        glassesStopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled,
                      self?.checkGlassesStop(operation: operation, targetID: targetID) == true else { return }
            }
        }
    }

    private func checkGlassesStop(operation: UUID, targetID: String?) -> Bool {
        guard isActive, glassesStopping, glassesStopOperation == operation else { return false }
        guard let targetID, ble?.isDeviceAvailable == true, ble?.deviceBluetoothIdentifier == targetID else {
            finishGlassesStream(reason: "STOP target unavailable or changed", confirmed: false)
            return false
        }
        switch glassesStopState.nextAction(now: ProcessInfo.processInfo.systemUptime) {
        case .wait: return true
        case .retryStop:
            let sent = ble?.stopTranslateRecording() ?? false
            logGlassesAudio("STOP retry=1 sent=\(sent); preserving tail and original deadline")
            return true
        case .drainedWithoutEnd:
            finishGlassesStream(reason: "first-generation 5s idle without END", confirmed: false)
        case .timedOut:
            finishGlassesStream(reason: "first-generation 45s END timeout", confirmed: false)
        }
        return false
    }

    private func scheduleSocketReadyTimeout() {
        cancelSocketReadyTimeout()
        let side = activeSide
        socketReadyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.isActive, self.activeSide == side else { return }
            if side == .glasses, self.glassesState.shouldSendStart {
                self.failGlassesStart(reason: "20s waiting for translation service ready")
                self.statusText = L10n.t("翻译服务连接超时，请重试", "Translation service timed out. Try again.")
                self.alertMessage = self.statusText
            } else if side == .phone, self.waitingPhoneSocketReady {
                self.waitingPhoneSocketReady = false
                self.manager?.close()
                self.statusText = L10n.t("翻译服务连接超时，请重试", "Translation service timed out. Try again.")
                self.alertMessage = self.statusText
            }
        }
    }

    private func cancelSocketReadyTimeout() {
        socketReadyTask?.cancel()
        socketReadyTask = nil
    }

    private func isGlassesStreamingActive() -> Bool {
        activeSide == .glasses && glassesRecording && glassesState.acceptsAudio
    }

    private func scheduleGlassesStartTimeout() {
        cancelGlassesStartTimeout()
        let timeout = ble?.deviceGeneration == .gen1G5K61 ? gen1GlassesStartTimeoutNs : glassesStartTimeoutNs
        DebugLogStore.logBLEEvent("translation START waiting", detail: "generation=\(ble?.deviceGeneration.rawValue ?? "unknown") timeoutSeconds=\(timeout / 1_000_000_000) requires=START_or_valid_Opus_DATA")
        glassesStartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard let self, !Task.isCancelled else { return }
            guard self.isActive, self.glassesState.isWaitingForDevice,
                  self.glassesConnecting, !self.glassesRecording, self.activeSide == .glasses else { return }
            self.failGlassesStart(reason: "\(timeout / 1_000_000_000)s elapsed without START or valid Opus DATA")
            self.alertMessage = L10n.t("未收到眼镜录音数据，请稍后重试", "No recording data received from the glasses. Please try again shortly.")
        }
    }

    private func cancelGlassesStartTimeout() {
        glassesStartTask?.cancel()
        glassesStartTask = nil
    }

    private func schedulePhoneAutoStop() {
        phoneAutoStopTask?.cancel()
        phoneAutoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.phoneRecordMaxNs ?? 60_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.phoneRecording || self.waitingPhoneSocketReady {
                self.stopPhoneRecording()
            }
        }
    }

    // MARK: - Status / text

    private func enterProcessingStatus(reason: String) {
        statusText = L10n.t("正在处理翻译…", "Processing translation…")
        scheduleProcessingStatusFallback(reason: reason)
    }

    private func scheduleProcessingStatusFallback(reason: String) {
        cancelProcessingStatusFallback()
        processingStatusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.processingFallbackNs ?? 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.settleProcessingStatus(reason: "fallback after \(reason)")
        }
    }

    private func cancelProcessingStatusFallback() {
        processingStatusTask?.cancel()
        processingStatusTask = nil
    }

    private func settleProcessingStatus(reason: String) {
        cancelProcessingStatusFallback()
        if !lastBackendErrorMessage.isEmpty {
            statusText = lastBackendErrorMessage
            return
        }
        if glassesConnecting || glassesRecording || waitingPhoneSocketReady || phoneRecording {
            return
        }
        let hasResult = !latestTranslation.isEmpty || !latestTranscript.isEmpty
        statusText = hasResult ? L10n.t("翻译结果已更新", "Translation updated") : L10n.t("点击下方按钮开始录音", "Tap a button below to start recording")
        print("[ConversationTranslation] processing settled reason=\(reason) hasResult=\(hasResult)")
    }

    private func appendSource(_ text: String) {
        cancelProcessingStatusFallback()
        let full = appendIncrementalText(
            segments: &sourceSegments,
            text: text,
            language: expectedSourceLanguageCode()
        )
        guard !full.isEmpty else { return }
        latestTranscript = full
        upsertMessage(sourceText: full, translatedText: nil, speech: nil, hasSpeech: nil)
        statusText = full
    }

    private func appendTranslation(_ text: String) {
        cancelProcessingStatusFallback()
        let full = appendIncrementalText(
            segments: &targetSegments,
            text: text,
            language: expectedTargetLanguageCode()
        )
        guard !full.isEmpty else { return }
        latestTranslation = full
        upsertMessage(sourceText: nil, translatedText: full, speech: nil, hasSpeech: nil)
        statusText = L10n.t("翻译结果已更新", "Translation updated")
    }

    private func expectedSourceLanguageCode() -> String {
        TranslationLanguage.code(
            forDisplayName: activeSide == .phone ? phoneLanguage : glassesLanguage
        )
    }

    private func expectedTargetLanguageCode() -> String {
        TranslationLanguage.code(
            forDisplayName: activeSide == .phone ? glassesLanguage : phoneLanguage
        )
    }

    private func upsertMessage(
        sourceText: String?,
        translatedText: String?,
        speech: Data?,
        hasSpeech: Bool?
    ) {
        guard let side = activeSide ?? currentTurnSide else { return }
        if let id = currentMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
            if let sourceText { messages[index].sourceText = sourceText }
            if let translatedText { messages[index].translatedText = translatedText }
            if let speech {
                if let existing = messages[index].speechData {
                    messages[index].speechData = existing + speech
                } else {
                    messages[index].speechData = speech
                }
            }
            if let hasSpeech { messages[index].hasSpeech = hasSpeech }
            persistConversation()
            return
        }
        let id = UUID()
        currentMessageID = id
        let source = side == .glasses ? glassesLanguage : phoneLanguage
        let target = side == .glasses ? phoneLanguage : glassesLanguage
        messages.append(
            ConversationTranslationMessage(
                id: id,
                side: side == .glasses ? .glasses : .phone,
                sourceLanguage: source,
                targetLanguage: target,
                sourceText: sourceText ?? (latestTranscript.isEmpty ? L10n.t("正在识别…", "Recognizing…") : latestTranscript),
                translatedText: translatedText ?? "",
                speechData: speech,
                hasSpeech: hasSpeech ?? (speech != nil)
            )
        )
        persistConversation()
    }

    private func persistConversation() {
        let history = messages.compactMap { message -> ConversationTranslationHistoryMessage? in
            let source = message.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translated = message.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty || (!source.isEmpty && source != L10n.t("正在识别…", "Recognizing…")) else { return nil }
            return ConversationTranslationHistoryMessage(
                id: message.id,
                side: message.side == .glasses ? "glasses" : "phone",
                sourceLanguage: message.sourceLanguage,
                targetLanguage: message.targetLanguage,
                sourceText: source == L10n.t("正在识别…", "Recognizing…") ? "" : source,
                translatedText: translated
            )
        }
        ConversationTranslationRecordStore.saveOrUpdate(
            id: conversationID,
            glassesLanguage: glassesLanguage,
            phoneLanguage: phoneLanguage,
            messages: history
        )
    }

    // MARK: - Incremental text (align Android)

    private func appendIncrementalText(
        segments: inout [String],
        text: String,
        language: String
    ) -> String {
        let segment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if segment.isEmpty { return segments.joined(separator: "\n") }
        if !matchesLanguage(segment, language: language) {
            return segments.joined(separator: "\n")
        }
        let normalizedSegment = normalizeForCompare(segment)
        let current = segments.joined(separator: "\n")
        let normalizedCurrent = normalizeForCompare(current)
        if segments.contains(where: { normalizeForCompare($0) == normalizedSegment })
            || normalizedCurrent.contains(normalizedSegment) {
            return current
        }
        if !current.isEmpty, normalizedSegment.contains(normalizedCurrent) {
            segments = [segment]
            return segment
        }
        if let containedIndex = segments.firstIndex(where: {
            let existing = normalizeForCompare($0)
            return !existing.isEmpty && normalizedSegment.contains(existing)
        }) {
            segments[containedIndex] = segment
            removeContainedSegments(&segments)
            return segments.joined(separator: "\n")
        }
        if let last = segments.last {
            let normalizedLast = normalizeForCompare(last)
            if normalizedSegment.contains(normalizedLast) {
                segments[segments.count - 1] = segment
                return segments.joined(separator: "\n")
            }
            if normalizedLast.contains(normalizedSegment) {
                return current
            }
            let overlap = findOverlapLength(normalizedLast, normalizedSegment)
            if overlap >= 2 {
                segments[segments.count - 1] = last + dropNormalizedPrefix(segment, count: overlap)
                removeContainedSegments(&segments)
                return segments.joined(separator: "\n")
            }
        }
        segments.append(segment)
        removeContainedSegments(&segments)
        return segments.joined(separator: "\n")
    }

    private func removeContainedSegments(_ segments: inout [String]) {
        let snapshot = segments
        segments = snapshot.filter { value in
            let normalized = normalizeForCompare(value)
            guard !normalized.isEmpty else { return false }
            return !snapshot.contains { other in
                other != value
                    && normalizeForCompare(other).count > normalized.count
                    && normalizeForCompare(other).contains(normalized)
            }
        }
    }

    private func findOverlapLength(_ previous: String, _ next: String) -> Int {
        let maxLen = min(previous.count, next.count)
        guard maxLen >= 2 else { return 0 }
        for length in stride(from: maxLen, through: 2, by: -1) {
            if previous.suffix(length) == next.prefix(length) {
                return length
            }
        }
        return 0
    }

    private func dropNormalizedPrefix(_ text: String, count: Int) -> String {
        var dropped = 0
        var index = text.startIndex
        while index < text.endIndex, dropped < count {
            if !isIgnoredForCompare(text[index]) {
                dropped += 1
            }
            index = text.index(after: index)
        }
        return String(text[index...])
    }

    private func normalizeForCompare(_ text: String) -> String {
        text.lowercased().filter { !isIgnoredForCompare($0) }
    }

    private func isIgnoredForCompare(_ char: Character) -> Bool {
        if char.isWhitespace { return true }
        guard let value = char.unicodeScalars.first?.value else { return false }
        return (0x0021...0x002F).contains(value)
            || (0x003A...0x0040).contains(value)
            || (0x005B...0x0060).contains(value)
            || (0x007B...0x007E).contains(value)
            || (0x3000...0x303F).contains(value)
            || (0xFF00...0xFFEF).contains(value)
    }

    private func matchesLanguage(_ text: String, language: String) -> Bool {
        let hasChinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let hasAsciiLetter = text.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
        switch language {
        case "zh": return hasChinese || !hasAsciiLetter
        case "en": return hasAsciiLetter || !hasChinese
        default: return true
        }
    }

    private func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        TranslationLanguage.code(forDisplayName: lhs)
            == TranslationLanguage.code(forDisplayName: rhs)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }
}

extension ConversationTranslationController: RealtimeTranslationManager.Callback {
    func onReady() {
        guard isActive else { return }
        cancelSocketReadyTimeout()
        statusText = glassesRecording || phoneRecording
            ? L10n.t("正在录音…", "Recording…")
            : L10n.t("翻译服务已就绪", "Translation service ready")
        if activeSide == .glasses, glassesConnecting, !glassesRecording, glassesState.shouldSendStart {
            startGlassesCommand()
        } else if activeSide == .phone, waitingPhoneSocketReady {
            beginPhoneAudioRecord()
        }
    }

    func onTaskStarted() {
        statusText = L10n.t("翻译任务已开始", "Translation task started")
    }

    func onTranscript(_ text: String) {
        appendSource(text)
    }

    func onTranscriptCompleted(_ text: String) {
        appendSource(text)
        enterProcessingStatus(reason: "transcript completed")
    }

    func onTranslation(_ text: String) {
        appendTranslation(text)
    }

    func onTranslationFinal(_ text: String) {
        appendTranslation(text)
    }

    func onTranslationCompleted() {
        settleProcessingStatus(reason: "translation completed")
    }

    func onSpeech(_ data: Data) {
        guard isActive, lastBackendErrorMessage.isEmpty else { return }
        cancelProcessingStatusFallback()
        let side = activeSide ?? currentTurnSide
        if side == .glasses {
            let wasOverflowed = deferredGlassesSpeech.overflowed
            switch deferredGlassesSpeech.receive(data) {
            case .deferred:
                if deferredGlassesSpeech.chunks.count == 1 || deferredGlassesSpeech.chunks.count.isMultiple(of: 50) {
                    DebugLogStore.logTranslation("glasses speech deferred", detail: "chunks=\(deferredGlassesSpeech.chunks.count) bytes=\(deferredGlassesSpeech.byteCount) recording=\(glassesRecording) draining=\(glassesStopping) canSend=\(manager?.canSendAudio() ?? false)")
                }
                statusText = L10n.t("正在录音，译文将在停止后播报", "Recording. Translation audio will play after you stop.")
            case .playNow:
                manager?.playSpeechOnPhone(data)
                statusText = L10n.t("正在播放译文语音…", "Playing translation audio…")
            case .overflow:
                if !wasOverflowed {
                    DebugLogStore.logTranslation("glasses deferred speech limit", detail: "bytes=\(deferredGlassesSpeech.byteCount) pcmUploadContinues=true")
                }
            case .discarded: return
            }
        } else if side == .phone {
            if manager?.playSpeechOnGlasses(data) != true {
                statusText = L10n.t("眼镜音频不可用", "Glasses audio unavailable")
            }
        }
        upsertMessage(sourceText: nil, translatedText: nil, speech: data, hasSpeech: true)
    }

    func onRecoverableError(_ message: String) {
        statusText = message.isEmpty ? L10n.t("正在处理上一句翻译…", "Processing previous translation…") : message
    }

    func onGlassesPlaybackStateChanged(_ state: RealtimeTranslationManager.GlassesPlaybackState) {
        guard isActive else { return }
        switch state {
        case .waiting:
            statusText = L10n.t("正在等待眼镜音频连接…", "Waiting for glasses audio…")
        case .playing:
            statusText = L10n.t("正在播放译文语音…", "Playing translation audio…")
        case .unavailable:
            statusText = L10n.t("眼镜音频不可用", "Glasses audio unavailable")
            alertMessage = L10n.t("无法通过眼镜播放译文，请连接系统蓝牙音频，并在音频输出中选择眼镜后重试", "Translation audio could not play through the glasses. Connect Bluetooth audio, select the glasses as the audio output, and try again.")
        }
    }

    func onError(_ message: String) {
        guard isActive else { return }
        cancelProcessingStatusFallback()
        lastBackendErrorMessage = message.isEmpty ? L10n.t("翻译服务异常", "Translation service error") : message
        glassesConnecting = false
        waitingPhoneSocketReady = false
        stopAllRecording(resetSocket: false)
        statusText = lastBackendErrorMessage
        alertMessage = lastBackendErrorMessage
    }

    func onClosed() {
        if !lastBackendErrorMessage.isEmpty {
            statusText = lastBackendErrorMessage
            return
        }
        if statusText == L10n.t("正在处理翻译…", "Processing translation…") {
            settleProcessingStatus(reason: "socket closed")
        } else if !glassesRecording, !phoneRecording, latestTranslation.isEmpty, latestTranscript.isEmpty {
            statusText = L10n.t("点击下方按钮开始录音", "Tap a button below to start recording")
        }
    }
}
