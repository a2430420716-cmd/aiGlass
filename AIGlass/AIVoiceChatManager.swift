import AVFoundation
import Combine
import Foundation

@MainActor
final class AIVoiceChatManager: ObservableObject {
    static let shared = AIVoiceChatManager()

    enum Phase: Equatable {
        case idle
        case waiting
        case listening
        case processing
        case speaking
        case failed(String)
    }

    private enum ConversationState {
        case idle
        case listening
        case thinking
        case speaking
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isEnabled = false
    /// AI 页按钮主动开启的连续对话会话。
    @Published private(set) var isManualSession = false
    /// 当前正在播放的用户语音气泡 id。
    @Published private(set) var playingVoiceMessageID: UUID?
    /// 当前正在播放的 AI 语音气泡 id。
    @Published private(set) var playingAIVoiceMessageID: UUID?

    private weak var ble: AstraA1BleManager?
    private var tokenProvider: (() -> String?)?
    private var frames: [Data] = []
    private var remotePlayer: AVPlayer?
    private var localPlayer: AVAudioPlayer?
    private var drainPlayer: AVAudioPlayer?
    private var bubblePlayer: AVAudioPlayer?
    private var remotePlaybackEndObserver: NSObjectProtocol?
    private var remotePlaybackFailureObserver: NSObjectProtocol?
    private var speechCompletion: (() -> Void)?
    private var drainCompletion: (() -> Void)?
    private var drainGeneration = 0
    private var state: ConversationState = .idle
    private var sessionActive = false
    private var recording = false
    private var generation = 0
    private var currentTurn = -1
    private var voiceChatCaptureEnabled = true

    private init() {}

    var statusText: String {
        switch phase {
        case .idle: return ""
        case .waiting: return L10n.t("正在开启眼镜麦克风…", "Enabling glasses mic…")
        case .listening: return L10n.t("正在聆听…", "Listening…")
        case .processing: return L10n.t("正在理解语音…", "Understanding speech…")
        case .speaking: return L10n.t("AI 正在回答…", "AI is answering…")
        case .failed(let message): return message
        }
    }

    var actionButtonTitle: String {
        switch phase {
        case .waiting, .listening, .processing, .speaking:
            return L10n.t("结束对话", "End Conversation")
        case .failed:
            return L10n.t("重试提问", "Retry")
        case .idle:
            return L10n.t("语音提问", "Voice Ask")
        }
    }

    var isActionEnabled: Bool {
        true
    }

    func bind(ble: AstraA1BleManager, tokenProvider: @escaping () -> String?) {
        self.ble = ble
        self.tokenProvider = tokenProvider
        ble.aiVoiceNotifyHandler = { [weak self] command, packet in
            // BLE notify 已在 MainActor；同步处理才能保证 status/data/turn 顺序。
            self?.handleNotify(command: command, packet: packet)
        }
    }

    /// 保留给旧调用方；语音唤醒开关已改由固件 `setwakeup0` 管理。
    @discardableResult
    func startContinuous() -> Bool {
        guard let ble else { return false }
        let sent = ble.startAIVoice(continuous: true)
        if sent {
            isEnabled = true
            isManualSession = false
            sessionActive = true
            state = .listening
            recording = true
            phase = .waiting
            frames.removeAll(keepingCapacity: true)
        }
        return sent
    }

    /// AI 页：开启/结束连续对话。
    @discardableResult
    func toggleManualSession() -> Bool {
        switch phase {
        case .waiting, .listening, .processing, .speaking:
            return stopManualSession()
        case .idle, .failed:
            return startManualSession()
        }
    }

    @discardableResult
    func startManualSession() -> Bool {
        guard let ble else { return false }
        if sessionActive {
            return stopManualSession()
        }
        // 对齐 Android AiFragment：手动入口也开启连续对话模式。
        let sent = ble.startAIVoice(continuous: true)
        if sent {
            isEnabled = true
            isManualSession = true
            sessionActive = true
            state = .listening
            recording = true
            phase = .waiting
            frames.removeAll(keepingCapacity: true)
        } else {
            phase = .failed(ble.mediaActionAlertMessage ?? L10n.t("无法开启语音提问", "Unable to start voice ask"))
        }
        return sent
    }

    @discardableResult
    func stopManualSession() -> Bool {
        let sent = ble?.stopAIVoice() ?? false
        if sent {
            resetSession(stopSpeechPlayback: true)
        } else {
            phase = .failed(ble?.mediaActionAlertMessage ?? L10n.t("语音提问关闭失败，请重试", "Failed to stop voice Q&A. Try again."))
        }
        return sent
    }

    @discardableResult
    func stop() -> Bool {
        let sent = ble?.stopAIVoice() ?? false
        if sent {
            resetSession(stopSpeechPlayback: true)
        }
        return sent
    }

    func resetAfterDisconnect() {
        resetSession(stopSpeechPlayback: true)
        stopBubblePlayback()
    }

    /// 对齐 Android `AiVoiceRecordManager.setVoiceChatCaptureEnabled`。
    /// 对话翻译等独占眼镜麦克风的功能打开时，忽略 AI 唤醒数据，避免串流误入连续对话。
    func setVoiceChatCaptureEnabled(_ enabled: Bool) {
        guard voiceChatCaptureEnabled != enabled else { return }
        voiceChatCaptureEnabled = enabled
        if !enabled {
            resetSession(stopSpeechPlayback: true)
        }
        print("[AIVoice] voice chat capture enabled=\(enabled)")
    }

    func togglePlayback(messageID: UUID, filePath: String) {
        if playingVoiceMessageID == messageID {
            stopBubblePlayback()
            return
        }
        stopBubblePlayback()
        stopSpeech()
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[AIVoice] missing audio file \(filePath)")
            return
        }
        do {
            try GlassesAudioRouteController.activate(.playback)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = BubblePlaybackDelegate.shared
            BubblePlaybackDelegate.shared.onFinish = { [weak self] in
                Task { @MainActor in
                    self?.playingVoiceMessageID = nil
                    self?.bubblePlayer = nil
                }
            }
            bubblePlayer = player
            playingVoiceMessageID = messageID
            player.play()
        } catch {
            print("[AIVoice] bubble play failed: \(error.localizedDescription)")
            playingVoiceMessageID = nil
        }
    }

    func toggleAIResponsePlayback(messageID: UUID, source: AIChatItem.AIVoiceSource) {
        if playingAIVoiceMessageID == messageID {
            stopSpeech()
            return
        }
        _ = playAIResponse(messageID: messageID, source: source)
    }

    /// 智能识图复用 Android 相同行为：speech_type=1 时自动播报，不生成语音气泡。
    func playSpeechResponse(_ result: ImageChatResult) {
        _ = playSpeech(result)
    }

    private func handleNotify(command: String, packet: Data) {
        guard voiceChatCaptureEnabled else { return }
        switch command {
        case "aivoicests":
            guard let status = AstraA1BleProtocol.parseAIVoiceStatus(packet) else {
                print("[AIVoice] invalid status packet bytes=\(packet.count)")
                return
            }
            handleStatus(status)
        case "aivoicedat":
            let newFrames = AstraA1BleProtocol.parseAIVoiceFrames(packet)
            guard !newFrames.isEmpty else { return }
            appendVoiceFrames(newFrames)
        case "aivoicetur":
            currentTurn = AstraA1BleProtocol.parseAIVoiceTurn(packet).map(Int.init) ?? -1
            print("[AIVoice] turn=\(currentTurn)")
        default:
            break
        }
    }

    private func handleStatus(_ status: UInt8) {
        print("[AIVoice] status=\(status) manual=\(isManualSession)")
        switch status {
        case 1:
            let shouldInterrupt = state == .speaking
            if state == .speaking || state == .thinking {
                generation += 1
            }
            sessionActive = true
            isEnabled = true
            beginTurn()
            if shouldInterrupt {
                stopSpeech()
            }
        case 3:
            finishUtterance()
        case 4:
            sessionActive = false
            isEnabled = false
            recording = false
            frames.removeAll(keepingCapacity: true)
            isManualSession = false
            if state != .speaking {
                state = .idle
                phase = .idle
            }
        case 0, 2:
            resetSession(stopSpeechPlayback: true)
        default:
            break
        }
    }

    private func beginTurn() {
        state = .listening
        recording = true
        phase = .listening
        frames.removeAll(keepingCapacity: true)
    }

    private func appendVoiceFrames(_ newFrames: [Data]) {
        var shouldInterrupt = false
        if !sessionActive {
            sessionActive = true
            isEnabled = true
        }
        if state == .speaking || state == .thinking {
            generation += 1
            shouldInterrupt = state == .speaking
            state = .listening
            recording = true
            frames.removeAll(keepingCapacity: true)
            phase = .listening
            print("[AIVoice] new utterance interrupted previous AI reply")
        } else if !recording {
            beginTurn()
        }
        frames.append(contentsOf: newFrames)
        print("[AIVoice] frames +\(newFrames.count), total=\(frames.count)")
        if shouldInterrupt {
            stopSpeech()
        }
    }

    private func finishUtterance() {
        if !recording, (state == .thinking || state == .speaking) {
            print("[AIVoice] ignore duplicate utterance end state=\(state)")
            return
        }

        sessionActive = true
        isEnabled = true
        recording = false
        state = .thinking
        generation += 1
        let token = generation
        let completedFrames = frames
        frames.removeAll(keepingCapacity: true)
        phase = .processing

        guard !completedFrames.isEmpty else {
            print("[AIVoice] utterance ended without audio frames")
            completeTurn(token)
            return
        }

        guard let authToken = tokenProvider?(), !authToken.isEmpty else {
            let message = L10n.t("未登录，无法发送语音", "Not signed in, cannot send voice")
            AIChatSession.shared.appendAIText(message)
            completeTurn(token)
            return
        }

        Task {
            do {
                let m4a = try AIVoiceM4aConverter.convertOpusFramesToM4A(completedFrames)
                let fileURL = try saveVoiceFile(m4a)
                print("[AIVoice] upload m4a bytes=\(m4a.count) frames=\(completedFrames.count) path=\(fileURL.path)")
                defer { try? FileManager.default.removeItem(at: fileURL) }

                let result = try await ArkChatService.voiceChat(
                    audio: m4a,
                    fileName: fileURL.lastPathComponent,
                    token: authToken
                )

                guard isCurrent(token) else {
                    print("[AIVoice] discard stale AI reply token=\(token) current=\(generation)")
                    return
                }

                let answer = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let asr = result.asr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let hasSpeech = result.speechType == 1
                    && !(result.speech?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

                if !asr.isEmpty {
                    print("[AIVoice] ASR text received but hidden to match Android chat UI: \(asr)")
                }

                if !answer.isEmpty {
                    AIChatSession.shared.appendAIText(answer)
                }

                if hasSpeech {
                    state = .speaking
                    phase = .speaking
                    let started = playSpeech(result) { [weak self] in
                        self?.completeTurn(token)
                    }
                    if !started {
                        completeTurn(token)
                    }
                } else {
                    completeTurn(token)
                }
            } catch {
                guard isCurrent(token) else { return }
                let message = error.localizedDescription.isEmpty ? L10n.t("语音提问失败", "Voice ask failed") : error.localizedDescription
                print("[AIVoice] failed: \(message)")
                AIChatSession.shared.appendAIText(message)
                completeTurn(token)
            }
        }
    }

    private func completeTurn(_ token: Int) {
        guard isCurrent(token) else { return }
        generation += 1
        guard sessionActive else {
            state = .idle
            phase = .idle
            isEnabled = false
            isManualSession = false
            return
        }

        state = .listening
        recording = true
        frames.removeAll(keepingCapacity: true)
        phase = .listening
        let sent = ble?.resumeAIVoiceListening() ?? false
        print("[AIVoice] AI reply finished, resume listen sent=\(sent)")
    }

    private func isCurrent(_ token: Int) -> Bool {
        generation == token
    }

    private func resetSession(stopSpeechPlayback: Bool) {
        generation += 1
        sessionActive = false
        isEnabled = false
        isManualSession = false
        state = .idle
        recording = false
        frames.removeAll(keepingCapacity: true)
        phase = .idle
        if stopSpeechPlayback {
            stopSpeech()
        }
    }

    private func saveVoiceFile(_ data: Data) throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("ai_voice_chat", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "ai_voice_chat_\(formatter.string(from: Date())).m4a"
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// 对齐 Android `playSpeech`：只播放 TTS，不向聊天列表添加语音消息。
    @discardableResult
    private func playSpeech(_ result: ImageChatResult, completion: (() -> Void)? = nil) -> Bool {
        guard result.speechType == 1,
              let raw = result.speech?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }

        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("/") {
            let value = ArkChatService.normalizeMediaURL(raw)
            guard URL(string: value) != nil else { return false }
            return playAIResponse(
                messageID: UUID(),
                source: .remoteURL(value),
                completion: completion
            )
        }

        let base64 = raw.components(separatedBy: ",").last ?? raw
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            print("[AIVoice] invalid speech base64")
            return false
        }
        do {
            let fileURL = try saveAIResponseFile(data)
            return playAIResponse(
                messageID: UUID(),
                source: .localFile(fileURL.path),
                completion: completion
            )
        } catch {
            print("[AIVoice] speech playback failed: \(error.localizedDescription)")
            return false
        }
    }

    private func saveAIResponseFile(_ data: Data) throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("ai_voice_reply", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ai_reply_\(UUID().uuidString).mp3")
        try data.write(to: url, options: [.atomic])
        return url
    }

    @discardableResult
    private func playAIResponse(
        messageID: UUID,
        source: AIChatItem.AIVoiceSource,
        completion: (() -> Void)? = nil
    ) -> Bool {
        stopBubblePlayback()
        stopSpeech()
        do {
            try GlassesAudioRouteController.activate(.playback)
            playingAIVoiceMessageID = messageID
            speechCompletion = completion

            switch source {
            case .remoteURL(let value):
                guard let url = URL(string: value) else {
                    playingAIVoiceMessageID = nil
                    speechCompletion = nil
                    return false
                }
                let item = AVPlayerItem(url: url)
                let player = AVPlayer(playerItem: item)
                remotePlayer = player
                remotePlaybackEndObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        let manager = AIVoiceChatManager.shared
                        guard manager.playingAIVoiceMessageID == messageID else { return }
                        manager.finishSpeechPlayback()
                    }
                }
                remotePlaybackFailureObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: item,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        let manager = AIVoiceChatManager.shared
                        guard manager.playingAIVoiceMessageID == messageID else { return }
                        manager.finishSpeechPlayback()
                    }
                }
                player.play()

            case .localFile(let path):
                let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
                player.delegate = AIResponsePlaybackDelegate.shared
                AIResponsePlaybackDelegate.shared.onFinish = { [weak self] in
                    Task { @MainActor in
                        guard self?.playingAIVoiceMessageID == messageID else { return }
                        self?.finishSpeechPlayback()
                    }
                }
                localPlayer = player
                guard player.play() else {
                    stopSpeech()
                    return false
                }
            }
            return true
        } catch {
            stopSpeech()
            print("[AIVoice] AI bubble playback failed: \(error.localizedDescription)")
            return false
        }
    }

    private func finishSpeechPlayback() {
        let completion = speechCompletion
        speechCompletion = nil
        clearSpeechPlayers()
        guard let completion else { return }
        drainBluetoothAudio(completion: completion)
    }

    private func stopSpeech() {
        speechCompletion = nil
        drainGeneration += 1
        drainCompletion = nil
        drainPlayer?.stop()
        drainPlayer = nil
        clearSpeechPlayers()
    }

    /// 对齐 Android AiVoiceTtsPlayer.DRAIN_SILENCE_MS：播报后向蓝牙输出写 800ms 静音，
    /// 等路由缓冲区排空后再恢复眼镜监听，避免尾音被当成下一轮提问。
    private func drainBluetoothAudio(completion: @escaping () -> Void) {
        drainGeneration += 1
        let token = drainGeneration
        drainCompletion = completion
        do {
            let player = try AVAudioPlayer(data: Self.bluetoothDrainSilenceWAV)
            player.delegate = AIResponseDrainDelegate.shared
            AIResponseDrainDelegate.shared.onFinish = { [weak self] in
                Task { @MainActor in
                    self?.finishBluetoothAudioDrain(token: token)
                }
            }
            drainPlayer = player
            guard player.play() else {
                finishBluetoothAudioDrain(token: token)
                return
            }
            // 委托异常时的保底；正常 800ms 播完会先收尾。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.finishBluetoothAudioDrain(token: token)
            }
        } catch {
            print("[AIVoice] bluetooth audio drain failed: \(error.localizedDescription)")
            finishBluetoothAudioDrain(token: token)
        }
    }

    private func finishBluetoothAudioDrain(token: Int) {
        guard token == drainGeneration else { return }
        drainGeneration += 1
        let completion = drainCompletion
        drainCompletion = nil
        drainPlayer?.stop()
        drainPlayer = nil
        completion?()
    }

    private static let bluetoothDrainSilenceWAV: Data = {
        let sampleRate: UInt32 = 16_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = Int(Double(sampleRate) * 0.8)
        let pcmByteCount = sampleCount * Int(channelCount) * Int(bitsPerSample / 8)
        var data = Data()

        func appendASCII(_ value: String) {
            data.append(contentsOf: value.utf8)
        }
        func appendLE16(_ value: UInt16) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
        func appendLE32(_ value: UInt32) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
        }

        appendASCII("RIFF")
        appendLE32(UInt32(36 + pcmByteCount))
        appendASCII("WAVEfmt ")
        appendLE32(16)
        appendLE16(1)
        appendLE16(channelCount)
        appendLE32(sampleRate)
        appendLE32(sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8))
        appendLE16(channelCount * (bitsPerSample / 8))
        appendLE16(bitsPerSample)
        appendASCII("data")
        appendLE32(UInt32(pcmByteCount))
        data.append(Data(count: pcmByteCount))
        return data
    }()

    private func clearSpeechPlayers() {
        if let remotePlaybackEndObserver {
            NotificationCenter.default.removeObserver(remotePlaybackEndObserver)
            self.remotePlaybackEndObserver = nil
        }
        if let remotePlaybackFailureObserver {
            NotificationCenter.default.removeObserver(remotePlaybackFailureObserver)
            self.remotePlaybackFailureObserver = nil
        }
        remotePlayer?.pause()
        remotePlayer = nil
        localPlayer?.stop()
        localPlayer = nil
        playingAIVoiceMessageID = nil
    }

    private func stopBubblePlayback() {
        bubblePlayer?.stop()
        bubblePlayer = nil
        playingVoiceMessageID = nil
    }
}

/// AVAudioPlayerDelegate 需 NSObject；用于气泡播完回 idle。
private final class BubblePlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    static let shared = BubblePlaybackDelegate()
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}

private final class AIResponsePlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    static let shared = AIResponsePlaybackDelegate()
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}

private final class AIResponseDrainDelegate: NSObject, AVAudioPlayerDelegate {
    static let shared = AIResponseDrainDelegate()
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
