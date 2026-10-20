import AVFoundation
import Foundation

/// 对齐安卓 `RealtimeTranslationManager`：拉取 ws_url → WebSocket → 发 PCM / 收文本与语音。
@MainActor
final class RealtimeTranslationManager: NSObject {
    @MainActor
    protocol Callback: AnyObject {
        func onReady()
        func onTaskStarted()
        func onTranscript(_ text: String)
        func onTranscriptCompleted(_ text: String)
        func onTranslation(_ text: String)
        func onSpeech(_ data: Data)
        func onTranslationCompleted()
        func onTranslationFinal(_ text: String)
        func onError(_ message: String)
        /// 可恢复错误（如「上一轮仍在处理」）：会话仍有效，不应中断录音。
        func onRecoverableError(_ message: String)
        func onClosed()
    }

    private weak var callback: Callback?
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    enum PlaybackRoute {
        /// 系统默认路由（通常眼镜已连时走蓝牙）。
        case `default`
        /// 强制手机扬声器。
        case phone
        /// 优先眼镜蓝牙输出。
        case glasses
    }

    private var opened = false
    private var ready = false
    private var initSent = false
    private var speechPlaybackEnabled = true
    /// 两个翻译页面自行选择播放路由，关闭默认自动播放避免重复播放。
    private var autoPlayIncomingSpeech = true
    private var phoneMicrophoneCaptureEnabled = false
    private var currentSourceLanguage = ""
    private var currentTargetLanguage = ""
    private var currentVoice = "Tina"
    private var currentWsURL = ""
    private var receiveLoopRunning = false
    private var connectionAttempt = TranslationConnectionAttempt()
    private var connectionTask: Task<Void, Never>?

    /// 对齐安卓输入门控：只有本地录制开启且未收尾时才允许发 PCM。
    private var inputState = TranslationAudioInputState()

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?

    private let sampleRate: Double = 16_000
    private let initDelayNs: UInt64 = 500_000_000
    /// 攒够约 100ms（16kHz / 16bit 单声道）再发，避免小包洪水撞上服务端 turn 边界。
    private let pcmChunkBytes = 3_200
    /// 服务端「上一轮仍在处理」后，若迟迟不再下发 ready，兜底恢复发包。
    private let turnBusyRecoveryNs: UInt64 = 2_500_000_000
    private var pendingPCM = Data()
    private var turnBusyRecoveryTask: Task<Void, Never>?

    init(callback: Callback) {
        self.callback = callback
        super.init()
    }

    func connect(sourceLanguage: String, targetLanguage: String, voice: String = "Tina", token: String) {
        close()
        currentSourceLanguage = sourceLanguage
        currentTargetLanguage = targetLanguage
        currentVoice = voice
        let attempt = connectionAttempt.begin()
        connectionTask = Task { [weak self] in
            await self?.fetchAndOpen(token: token, attempt: attempt)
        }
    }

    func updateLanguage(sourceLanguage: String, targetLanguage: String) {
        currentSourceLanguage = sourceLanguage
        currentTargetLanguage = targetLanguage
        guard opened else { return }
        sendJSON([
            "type": "update_language",
            "source_lang": sourceLanguage,
            "target_lang": targetLanguage
        ])
    }

    func canSendAudio() -> Bool {
        inputState.canSendAudio(opened: opened, ready: ready)
    }

    @discardableResult
    func sendPCM(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        // 未过输入门控直接丢弃，对齐安卓 pcm dropped。
        guard canSendAudio() else {
            pendingPCM.removeAll(keepingCapacity: true)
            return false
        }
        pendingPCM.append(data)
        guard pendingPCM.count >= pcmChunkBytes else { return true }
        let chunk = pendingPCM
        pendingPCM.removeAll(keepingCapacity: true)
        return sendPCMChunk(chunk)
    }

    @discardableResult
    private func sendPCMChunk(_ chunk: Data) -> Bool {
        guard canSendAudio(), !chunk.isEmpty, let task = webSocketTask else {
            return false
        }
        task.send(.data(chunk)) { error in
            if let error {
                print("[RealtimeTranslation] pcm send failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    @discardableResult
    func markLocalRecordingStarted() -> Bool {
        let allowed = inputState.start(opened: opened, ready: ready, now: Date())
        print("[RealtimeTranslation] record input opened allowed=\(allowed)")
        return allowed
    }

    func markLocalRecordingStopped(reason: String) {
        // Callers close the recording gate before finish(). Flush the final <100ms first.
        flushPendingPCM()
        inputState.stop(now: Date())
        print("[RealtimeTranslation] record input closed reason=\(reason)")
    }

    private func flushPendingPCM() {
        guard canSendAudio(), !pendingPCM.isEmpty else { return }
        let chunk = pendingPCM
        pendingPCM.removeAll(keepingCapacity: true)
        _ = sendPCMChunk(chunk)
    }

    func setSpeechPlaybackEnabled(_ enabled: Bool) {
        speechPlaybackEnabled = enabled
        if !enabled {
            stopPlayback()
        }
    }

    func setAutoPlayIncomingSpeech(_ enabled: Bool) {
        autoPlayIncomingSpeech = enabled
        if !enabled {
            stopPlayback()
        }
        print("[RealtimeTranslation] autoPlayIncomingSpeech=\(enabled)")
    }

    func setPhoneMicrophoneCaptureEnabled(_ enabled: Bool) {
        phoneMicrophoneCaptureEnabled = enabled
    }

    func resetSpeechPlaybackForTurn() {
        stopPlayback()
    }

    func playSpeechOnPhone(_ data: Data) {
        guard !data.isEmpty else { return }
        playPCM(data, route: .phone)
    }

    @discardableResult
    func playSpeechOnGlasses(_ data: Data, requiresBluetoothOutput: Bool = false) -> Bool {
        guard !data.isEmpty else { return false }
        return playPCM(data, route: .glasses, requiresBluetoothOutput: requiresBluetoothOutput)
    }

    /// A BLE connection alone does not establish the classic Bluetooth audio route.
    func prepareGlassesSpeechOutput() -> Bool {
        applyPlaybackRoute(.glasses)
        return GlassesAudioRouteController.isOutputOnBluetooth
    }

    func replaySpeech(_ data: Data) {
        replaySpeechOnDefault(data)
    }

    @discardableResult
    func replaySpeechOnPhone(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        stopPlayback()
        playPCM(data, route: .phone)
        return true
    }

    @discardableResult
    func replaySpeechOnGlasses(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        stopPlayback()
        return playSpeechOnGlasses(data)
    }

    private func replaySpeechOnDefault(_ data: Data) {
        guard !data.isEmpty else { return }
        stopPlayback()
        playPCM(data, route: .default)
    }

    func finish() {
        flushPendingPCM()
        pendingPCM.removeAll(keepingCapacity: true)
        turnBusyRecoveryTask?.cancel()
        turnBusyRecoveryTask = nil
        ready = false
        markInputClosing(reason: "finish")
        if opened {
            sendJSON(["type": "stop"])
            print("[RealtimeTranslation] stop sent")
        }
    }

    func close() {
        connectionAttempt.cancel()
        connectionTask?.cancel()
        connectionTask = nil
        receiveLoopRunning = false
        turnBusyRecoveryTask?.cancel()
        turnBusyRecoveryTask = nil
        pendingPCM.removeAll(keepingCapacity: true)
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        opened = false
        ready = false
        initSent = false
        resetInputGate()
        stopPlayback()
    }

    // MARK: - Connect

    private func fetchAndOpen(token: String, attempt: UInt64) async {
        do {
            let data = try await APIClient.getRaw(
                path: "translate/ws_url",
                authorization: token
            )
            guard connectionAttempt.isCurrent(attempt), !Task.isCancelled else { return }
            let raw = String(data: data, encoding: .utf8) ?? ""
            print("[RealtimeTranslation] ws_url response: \(raw)")
            guard let wsURLString = Self.parseWsURL(from: data),
                  let wsURL = URL(string: wsURLString) else {
                callback?.onError("WebSocket url is empty")
                return
            }
            openWebSocket(wsURL)
        } catch {
            guard connectionAttempt.isCurrent(attempt), !Task.isCancelled else { return }
            callback?.onError(error.localizedDescription)
        }
    }

    private func openWebSocket(_ url: URL) {
        currentWsURL = url.absoluteString
        print("[RealtimeTranslation] connect websocket: \(currentWsURL)")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        self.session = session
        var request = URLRequest(url: url)
        AppRequestHeaders.apply(to: &request)
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        initSent = false
        opened = false
        ready = false
        resetInputGate()
        task.resume()
        opened = true
        startReceiveLoop()
        Task {
            try? await Task.sleep(nanoseconds: initDelayNs)
            guard opened, !initSent, webSocketTask === task else { return }
            sendInit()
        }
    }

    private func startReceiveLoop() {
        receiveLoopRunning = true
        receiveNext()
    }

    private func receiveNext() {
        guard receiveLoopRunning, let task = webSocketTask else { return }
        let attempt = connectionAttempt.current
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.receiveLoopRunning,
                      self.connectionAttempt.isCurrent(attempt),
                      self.webSocketTask === task else { return }
                switch result {
                case .failure(let error):
                    self.receiveLoopRunning = false
                    self.opened = false
                    self.ready = false
                    self.inputState.close()
                    self.stopPlayback()
                    print("[RealtimeTranslation] websocket failed: \(error.localizedDescription)")
                    self.callback?.onError(error.localizedDescription)
                    self.callback?.onClosed()
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleTextMessage(text)
                    case .data(let data):
                        print("[RealtimeTranslation] speech binary received: bytes=\(data.count)")
                        self.callback?.onSpeech(data)
                        if self.autoPlayIncomingSpeech {
                            self.playPCM(data, route: .default)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveNext()
                }
            }
        }
    }

    // MARK: - Messages

    private func handleTextMessage(_ text: String) {
        print("[RealtimeTranslation] message received: \(text.prefix(500))")
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let type = stringValue(json["type"])
        switch type {
        case "connected":
            sendInit()
        case "ready":
            turnBusyRecoveryTask?.cancel()
            turnBusyRecoveryTask = nil
            ready = true
            // A repeated ready resumes the current recording; it must not mute its PCM.
            // A locally stopped turn stays closed even if a late ready arrives.
            inputState.serviceReady()
            callback?.onReady()
        case "task_started":
            callback?.onTaskStarted()
        case "transcript", "source_text":
            let value = Self.normalizeSocketText(stringValue(json["text"]))
            if !value.isEmpty { callback?.onTranscript(value) }
        case "transcript_done", "source_text_done":
            let value = Self.normalizeSocketText(stringValue(json["text"])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { callback?.onTranscriptCompleted(value) }
        case "translation", "translation_done", "translation_text", "translated_text", "translated_text_delta", "translation_audio":
            handleTranslationMessage(json)
        case "translated_text_final":
            handleTranslationMessage(json)
            markBackendTurnFinished(reason: "translated_text_final")
            let finalText = Self.normalizeSocketText(stringValue(json["text"])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalText.isEmpty { callback?.onTranslationFinal(finalText) }
        case "translation_audio_done", "translation_completed":
            if type == "translation_audio_done" {
                markBackendTurnFinished(reason: "translation_audio_done")
            } else {
                ready = false
                markInputClosing(reason: "translation_completed")
            }
            callback?.onTranslationCompleted()
        case "stopped":
            ready = false
            markInputClosing(reason: "stopped")
        case "error", "service_disconnected":
            let message = stringValue(json["message"]).ifBlank(text)
            // 「上一轮仍在处理」只是节流提示：暂停发包等下一个 ready，不要断开会话。
            if type == "error", Self.isTurnBusyMessage(message) {
                inputState.beginBackendProcessing()
                pendingPCM.removeAll(keepingCapacity: true)
                scheduleTurnBusyRecovery()
                print("[RealtimeTranslation] turn busy, pause sending: \(message)")
                callback?.onRecoverableError(message)
                return
            }
            ready = false
            if type == "service_disconnected" {
                opened = false
                resetInputGate()
                stopPlayback()
            } else {
                markInputClosing(reason: "error")
            }
            callback?.onError(message)
        default:
            break
        }
    }

    private func handleTranslationMessage(_ json: [String: Any]) {
        let translation = Self.normalizeSocketText(
            stringValue(json["text"])
                .ifBlank(stringValue(json["translation"]))
                .ifBlank(stringValue(json["translated_text"]))
        )
        if !translation.isEmpty {
            callback?.onTranslation(translation)
        }
        let audioBase64 = stringValue(json["audio"])
        if !audioBase64.isEmpty,
           let bytes = Data(base64Encoded: audioBase64, options: .ignoreUnknownCharacters) {
            callback?.onSpeech(bytes)
            if autoPlayIncomingSpeech {
                playPCM(bytes, route: .default)
            }
        }
    }

    private func markBackendTurnFinished(reason: String) {
        inputState.backendTurnFinished()
        print("[RealtimeTranslation] backend turn finished reason=\(reason) canSend=\(canSendAudio())")
    }

    private func markInputClosing(reason: String) {
        inputState.stop(now: Date())
        print("[RealtimeTranslation] audio input closing reason=\(reason)")
    }

    private func resetInputGate() {
        inputState.close()
    }

    /// 服务端 turn 节流提示，例如
    /// `Previous turn is still processing, please wait for completion before sending new audio`。
    private static func isTurnBusyMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("previous turn") { return true }
        return lower.contains("still processing") && lower.contains("audio")
    }

    /// 服务端未再下发 ready 时的兜底：短暂退避后恢复发包，避免录音全程哑掉。
    private func scheduleTurnBusyRecovery() {
        turnBusyRecoveryTask?.cancel()
        turnBusyRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.turnBusyRecoveryNs ?? 2_500_000_000)
            guard let self, !Task.isCancelled, opened else { return }
            inputState.backendTurnFinished()
            print("[RealtimeTranslation] turn busy recovery: canSend=\(canSendAudio())")
        }
    }

    private func sendInit() {
        guard !initSent else { return }
        initSent = true
        sendJSON([
            "type": "init",
            "source_lang": currentSourceLanguage,
            "target_lang": currentTargetLanguage,
            "voice": currentVoice
        ])
        print("[RealtimeTranslation] init sent source=\(currentSourceLanguage) target=\(currentTargetLanguage)")
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { error in
            if let error {
                print("[RealtimeTranslation] json send failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - PCM Playback

    @discardableResult
    private func playPCM(_ data: Data, route: PlaybackRoute, requiresBluetoothOutput: Bool = false) -> Bool {
        guard speechPlaybackEnabled, !data.isEmpty else { return false }
        ensurePlaybackEngine(route: route)
        if requiresBluetoothOutput, !GlassesAudioRouteController.isOutputOnBluetooth {
            stopPlayback()
            print("[RealtimeTranslation] glasses playback blocked: output is not Bluetooth")
            return false
        }
        guard let playerNode, let playbackFormat else { return false }

        guard let buffer = TranslationPCMPlayback.makeBuffer(from: data, format: playbackFormat) else {
            print("[RealtimeTranslation] invalid playback PCM bytes=\(data.count) format=\(playbackFormat)")
            return false
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        return true
    }

    private func ensurePlaybackEngine(route: PlaybackRoute) {
        applyPlaybackRoute(route)
        if audioEngine != nil, playerNode != nil { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = TranslationPCMPlayback.makeFormat() else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            audioEngine = engine
            playerNode = player
            playbackFormat = format
        } catch {
            print("[RealtimeTranslation] playback engine failed: \(error.localizedDescription)")
        }
    }

    private func applyPlaybackRoute(_ route: PlaybackRoute) {
        let session = AVAudioSession.sharedInstance()
        do {
            switch route {
            case .phone:
                // 强制手机外放，避免眼镜已连时 TTS 仍走蓝牙。
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .mixWithOthers]
                )
                try session.overrideOutputAudioPort(.speaker)
            case .glasses:
                try GlassesAudioRouteController.activate(phoneMicrophoneCaptureEnabled ? .playAndRecord : .playback)
                if phoneMicrophoneCaptureEnabled,
                   let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                    try session.setPreferredInput(microphone)
                }
            case .default:
                if phoneMicrophoneCaptureEnabled {
                    try GlassesAudioRouteController.activate(.playAndRecord)
                    if let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                        try session.setPreferredInput(microphone)
                    }
                } else if GlassesAudioRouteController.glassesConnected {
                    try GlassesAudioRouteController.activate(.playback)
                } else {
                    try session.setCategory(.playback, mode: .default, options: [])
                    try session.setActive(true)
                }
            }
        } catch {
            print("[RealtimeTranslation] apply route \(route) failed: \(error.localizedDescription)")
        }
    }

    private func stopPlayback() {
        playerNode?.stop()
        audioEngine?.stop()
        if let playerNode, let audioEngine {
            audioEngine.detach(playerNode)
        }
        playerNode = nil
        audioEngine = nil
        playbackFormat = nil
    }

    // MARK: - Helpers

    static func parseWsURL(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let direct = stringValueStatic(json["ws_url"])
        if !direct.isEmpty { return direct }
        if let dataObj = json["data"] as? [String: Any] {
            let url = stringValueStatic(dataObj["ws_url"])
            if !url.isEmpty { return url }
        }
        if let result = json["result"] as? [String: Any] {
            let url = stringValueStatic(result["ws_url"])
            if !url.isEmpty { return url }
        }
        return nil
    }

    private func stringValue(_ any: Any?) -> String {
        Self.stringValueStatic(any)
    }

    private static func stringValueStatic(_ any: Any?) -> String {
        switch any {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return ""
        }
    }

    private static func normalizeSocketText(_ text: String) -> String {
        text
    }
}

private extension String {
    func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
