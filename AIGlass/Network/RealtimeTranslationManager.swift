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
        func onGlassesPlaybackStateChanged(_ state: GlassesPlaybackState)
        func onClosed()
    }

    private weak var callback: Callback?
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var urlLookupSession: URLSession?
    enum PlaybackRoute: Equatable {
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
    private var connectionReadyTimeoutTask: Task<Void, Never>?
    var isConnecting: Bool { connectionAttempt.isConnecting }
    private let diagnosticID = String(UUID().uuidString.prefix(8))
    private var pcmQueuedChunks = 0
    private var pcmQueuedBytes = 0
    private var pcmSentChunks = 0
    private var pcmSentBytes = 0
    private var pcmDroppedBytes = 0
    private var pcmSendErrors = 0
    private var queueWaitTiming = TranslationAudioTiming()
    private var sendCompletionTiming = TranslationAudioTiming()
    private var sendCallbackTiming = TranslationAudioTiming()
    private var receivedEvents: [String: Int] = [:]
    private var sendQueue = TranslationSocketSendQueue()
    private var transportMonitorTask: Task<Void, Never>?
    private var pingStartedAt: TimeInterval?
    private var lastPingAt: TimeInterval = 0
    private var lastBacklogLogAt: TimeInterval = 0

    /// 对齐安卓输入门控：只有本地录制开启且未收尾时才允许发 PCM。
    private var inputState = TranslationAudioInputState()

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var activePlaybackRoute: PlaybackRoute?
    private var playbackUsesPhoneMicrophone = false
    private var playbackChunks = 0
    private var playbackGeneration: UInt64 = 0
    private var playbackMonitorTask: Task<Void, Never>?
    private var waitingGlassesAudio = TranslationGlassesPlaybackQueue()
    private var glassesRouteRetryTask: Task<Void, Never>?
    enum GlassesPlaybackState { case waiting, playing, unavailable }

    private let initDelayNs: UInt64 = 500_000_000
    /// 攒够约 100ms（16kHz / 16bit 单声道）再发，避免小包洪水撞上服务端 turn 边界。
    private let pcmChunkBytes = 3_200
    /// 服务端「上一轮仍在处理」后，若迟迟不再下发 ready，兜底恢复发包。
    private let turnBusyRecoveryNs: UInt64 = 700_000_000
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
        pcmQueuedChunks = 0
        pcmQueuedBytes = 0
        pcmSentChunks = 0
        pcmSentBytes = 0
        pcmDroppedBytes = 0
        pcmSendErrors = 0
        queueWaitTiming = TranslationAudioTiming()
        sendCompletionTiming = TranslationAudioTiming()
        sendCallbackTiming = TranslationAudioTiming()
        receivedEvents.removeAll()
        logFlow("connect", "source=\(sourceLanguage) target=\(targetLanguage) inputRate=16000 playbackRate=24000 pcmBits=16 channels=1")
        connectionReadyTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self,
                  self.connectionAttempt.isCurrent(attempt), self.isConnecting else { return }
            self.logFlow("connection ready timeout", "stage=\(self.opened ? "waiting-service-ready" : "fetching-url") budgetSeconds=20")
            self.close()
            self.callback?.onError(L10n.t("翻译服务连接超时，请检查网络后重试", "Translation service timed out. Check the network and try again."))
        }
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
        // If Bluetooth disappears mid-buffer, prevent its remaining speech from
        // being picked up by the phone mic after iOS falls back to the speaker.
        if phoneMicrophoneCaptureEnabled, inputState.hasScheduledPlayback,
           !GlassesAudioRouteController.isOutputOnBluetooth { return false }
        return inputState.canSendAudio(opened: opened, ready: ready)
    }

    @discardableResult
    func sendPCM(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        // 未过输入门控直接丢弃，对齐安卓 pcm dropped。
        guard canSendAudio() else {
            let firstDrop = pcmDroppedBytes == 0
            pcmDroppedBytes += data.count + pendingPCM.count
            if firstDrop { logFlow("PCM gated", gateDetail) }
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
        guard enqueueSend(chunk, kind: .pcm) else { return false }
        pcmQueuedChunks += 1
        pcmQueuedBytes += chunk.count
        drainSendQueue(task: task)
        // Accepted locally, not proof of receipt by the backend.
        return true
    }

    @discardableResult
    func markLocalRecordingStarted() -> Bool {
        let allowed = inputState.start(opened: opened, ready: ready, now: Date())
        logFlow("input start", "allowed=\(allowed) \(gateDetail)")
        print("[RealtimeTranslation] record input opened allowed=\(allowed)")
        return allowed
    }

    func markLocalRecordingStopped(reason: String) {
        // Callers close the recording gate before finish(). Flush the final <100ms first.
        flushPendingPCM()
        inputState.stop(now: Date())
        logFlow("input stop", "reason=\(reason) \(audioSummary)")
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
    func playSpeechOnGlasses(_ data: Data, requiresBluetoothOutput: Bool = true) -> Bool {
        guard speechPlaybackEnabled, !data.isEmpty, data.count.isMultiple(of: 2) else { return false }
        if !requiresBluetoothOutput {
            return playPCM(data, route: .glasses)
        }
        if waitingGlassesAudio.chunks.isEmpty,
           playPCM(data, route: .glasses, requiresBluetoothOutput: true) {
            callback?.onGlassesPlaybackStateChanged(.playing)
            return true
        }
        guard waitingGlassesAudio.append(data, now: ProcessInfo.processInfo.systemUptime) else {
            failGlassesPlayback(reason: "route queue limit")
            return false
        }
        startGlassesRouteRetry()
        // Audio was retained while waiting for the actual Bluetooth output.
        return true
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
        logFlow("finish", "\(gateDetail) \(audioSummary)")
        // A stopped pending start must not open a socket or microphone later.
        if isConnecting {
            close()
            return
        }
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
        if webSocketTask != nil || connectionTask != nil {
            logFlow("close", audioSummary)
        }
        connectionAttempt.cancel()
        connectionReadyTimeoutTask?.cancel()
        connectionReadyTimeoutTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        urlLookupSession?.invalidateAndCancel()
        urlLookupSession = nil
        receiveLoopRunning = false
        turnBusyRecoveryTask?.cancel()
        turnBusyRecoveryTask = nil
        stopTransportMonitor()
        sendQueue.reset()
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
        guard connectionAttempt.isCurrent(attempt), !Task.isCancelled else { return }
        // Each retry owns its lookup transport. A stalled lookup must be
        // cancellable without keeping later starts on the shared HTTP session.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let lookupSession = URLSession(configuration: configuration)
        urlLookupSession = lookupSession
        defer {
            lookupSession.invalidateAndCancel()
            if urlLookupSession === lookupSession { urlLookupSession = nil }
        }
        do {
            let data = try await APIClient.getRaw(
                path: "translate/ws_url",
                authorization: token,
                session: lookupSession
            )
            guard connectionAttempt.isCurrent(attempt), !Task.isCancelled else { return }
            let raw = String(data: data, encoding: .utf8) ?? ""
            print("[RealtimeTranslation] ws_url response: \(raw)")
            guard let wsURLString = Self.parseWsURL(from: data),
                  let wsURL = URL(string: wsURLString) else {
                logFlow("URL invalid")
                close()
                callback?.onError("WebSocket url is empty")
                return
            }
            openWebSocket(wsURL)
        } catch {
            guard connectionAttempt.isCurrent(attempt), !Task.isCancelled else { return }
            logFlow("URL request failed", error.localizedDescription)
            close()
            callback?.onError(error.localizedDescription)
        }
    }

    private func openWebSocket(_ url: URL) {
        currentWsURL = url.absoluteString
        // Deliberately exclude URL query/user info, which may carry credentials.
        logFlow("socket requested", "host=\(url.host ?? "") port=\(url.port ?? (url.scheme == "wss" ? 443 : 80))")
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
        startTransportMonitor(task: task)
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
                    self.handleSocketFailure(error, task: task, operation: "receive")
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleTextMessage(text)
                    case .data(let data):
                        self.logReceived("speech_binary", detail: "bytes=\(data.count)")
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
            logReceived("invalid_json", detail: "bytes=\(text.utf8.count)")
            return
        }
        let type = stringValue(json["type"])
        logReceived(type, detail: "textChars=\(stringValue(json["text"]).count) audioBase64Chars=\(stringValue(json["audio"]).count)")
        switch type {
        case "connected":
            sendInit()
        case "ready":
            finishConnectionStartup()
            turnBusyRecoveryTask?.cancel()
            turnBusyRecoveryTask = nil
            ready = true
            // A repeated ready resumes the current recording; it must not mute its PCM.
            // A locally stopped turn stays closed even if a late ready arrives.
            inputState.serviceReady()
            logFlow("service ready", gateDetail)
            callback?.onReady()
        case "task_started":
            callback?.onTaskStarted()
        case "speech_started":
            // Remote VAD can resume an existing local recording, never start a mic.
            markBackendTurnFinished(reason: "speech_started")
        case "speech_stopped":
            // VAD ending a sentence is not a server rejection. Keep uploading the
            // next sentence; only an explicit busy notice should apply backoff.
            logFlow("speech boundary", "continueInput=true \(gateDetail)")
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
        case "warn", "error", "service_disconnected":
            let message = stringValue(json["message"]).ifBlank(text)
            logFlow("server notice", "type=\(type) message=\(String(stringValue(json["message"]).prefix(300))) \(audioSummary)")
            // 「上一轮仍在处理」只是节流提示：暂停发包等下一个 ready，不要断开会话。
            if type != "service_disconnected", Self.isTurnBusyMessage(message) {
                markBackendTurnBusy(reason: type)
                print("[RealtimeTranslation] turn busy, pause sending: \(message)")
                callback?.onRecoverableError(L10n.t("正在处理上一句翻译…", "Processing previous translation…"))
                return
            }
            // Other warnings are diagnostic, not a terminal recording failure.
            if type == "warn" { return }
            close()
            callback?.onError(Self.localizedServiceError(message, disconnected: type == "service_disconnected"))
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
        turnBusyRecoveryTask?.cancel()
        turnBusyRecoveryTask = nil
        inputState.backendTurnFinished()
        logFlow("turn finished", "reason=\(reason) \(gateDetail)")
        print("[RealtimeTranslation] backend turn finished reason=\(reason) canSend=\(canSendAudio())")
    }

    private func markBackendTurnBusy(reason: String) {
        guard inputState.recording, opened, ready else { return }
        inputState.beginBackendProcessing()
        pcmDroppedBytes += pendingPCM.count
        pendingPCM.removeAll(keepingCapacity: true)
        logFlow("turn busy", "reason=\(reason) holdMs=700 \(gateDetail)")
        scheduleTurnBusyRecovery()
    }

    private func markInputClosing(reason: String) {
        inputState.stop(now: Date())
        logFlow("input closing", "reason=\(reason) \(gateDetail)")
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
            try? await Task.sleep(nanoseconds: self?.turnBusyRecoveryNs ?? 700_000_000)
            guard let self, !Task.isCancelled, opened, ready, inputState.recording else { return }
            inputState.backendTurnFinished()
            logFlow("busy recovery", gateDetail)
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
              let task = webSocketTask else { return }
        let type = stringValue(object["type"])
        logFlow("JSON queued", "type=\(type) source=\(currentSourceLanguage) target=\(currentTargetLanguage)")
        guard enqueueSend(data, kind: .json(type)) else { return }
        drainSendQueue(task: task)
    }

    private func enqueueSend(_ data: Data, kind: TranslationSocketSendQueue.Kind) -> Bool {
        guard let task = webSocketTask, opened, receiveLoopRunning else { return false }
        guard sendQueue.append(data, kind: kind, now: ProcessInfo.processInfo.systemUptime) else {
            logFlow("send backlog limit", audioSummary)
            handleSocketFailure(translationTransportError(), task: task, operation: "send backlog limit")
            return false
        }
        return true
    }

    private func drainSendQueue(task: URLSessionWebSocketTask) {
        guard webSocketTask === task, opened, receiveLoopRunning,
              let packet = sendQueue.takeNext() else { return }
        let message: URLSessionWebSocketTask.Message
        switch packet.kind {
        case .pcm: message = .data(packet.data)
        case .json: message = .string(String(decoding: packet.data, as: UTF8.self))
        }
        let attempt = connectionAttempt.current
        let sendAt = ProcessInfo.processInfo.systemUptime
        queueWaitTiming.record(at: sendAt, delay: sendAt - packet.queuedAt)
        task.send(message) { [weak self] error in
            let completedAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                guard let self, self.connectionAttempt.isCurrent(attempt), self.webSocketTask === task else { return }
                guard self.sendQueue.complete(packet.id) else { return }
                self.sendCompletionTiming.record(at: completedAt, delay: completedAt - sendAt)
                self.sendCallbackTiming.record(at: completedAt, delay: ProcessInfo.processInfo.systemUptime - completedAt)
                if let error {
                    if case .pcm = packet.kind { self.pcmSendErrors += 1 }
                    self.handleSocketFailure(error, task: task, operation: "queued send")
                } else {
                    switch packet.kind {
                    case .pcm:
                        self.pcmSentChunks += 1
                        self.pcmSentBytes += packet.data.count
                        if self.pcmSentChunks == 1 || self.pcmSentChunks.isMultiple(of: 50) {
                            self.logFlow("PCM send completed", self.audioSummary)
                        }
                    case .json(let type):
                        self.logFlow("JSON send completed", "type=\(type) \(type == "stop" ? self.audioSummary : "")")
                    }
                    self.drainSendQueue(task: task)
                }
            }
        }
    }

    private func translationTransportError() -> NSError {
        NSError(domain: "TranslationTransport", code: -1001, userInfo: [NSLocalizedDescriptionKey:
            L10n.t("翻译网络发送超时，请检查网络后重试", "Translation audio could not be sent in time. Check the network and try again.")])
    }

    private func startTransportMonitor(task: URLSessionWebSocketTask) {
        stopTransportMonitor()
        lastPingAt = ProcessInfo.processInfo.systemUptime
        lastBacklogLogAt = lastPingAt
        let attempt = connectionAttempt.current
        transportMonitorTask = Task { @MainActor [weak self, weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, let task,
                      self.connectionAttempt.isCurrent(attempt), self.webSocketTask === task,
                      self.receiveLoopRunning, self.opened else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let oldestAge = self.sendQueue.oldestAge(now: now)
                if oldestAge >= TranslationSocketSendQueue.sendTimeout ||
                    self.pingStartedAt.map({ now - $0 >= 10 }) == true {
                    let operation = oldestAge >= TranslationSocketSendQueue.sendTimeout ? "send timeout" : "ping timeout"
                    self.logFlow(operation, "oldestAge=\(oldestAge) \(self.audioSummary)")
                    self.handleSocketFailure(self.translationTransportError(), task: task, operation: operation)
                    return
                }
                if oldestAge >= 2, now - self.lastBacklogLogAt >= 5 {
                    self.lastBacklogLogAt = now
                    self.logFlow("send backlog", "oldestAge=\(oldestAge) \(self.audioSummary)")
                }
                if self.pingStartedAt == nil, now - self.lastPingAt >= 20 {
                    self.pingStartedAt = now
                    self.lastPingAt = now
                    self.logFlow("ping sent")
                    task.sendPing { [weak self] error in
                        Task { @MainActor in
                            guard let self, self.connectionAttempt.isCurrent(attempt),
                                  self.webSocketTask === task, self.receiveLoopRunning else { return }
                            let elapsed = ProcessInfo.processInfo.systemUptime - now
                            self.pingStartedAt = nil
                            if let error {
                                self.handleSocketFailure(error, task: task, operation: "ping")
                            } else {
                                self.logFlow("pong received", "roundTripMs=\(Int(elapsed * 1_000))")
                            }
                        }
                    }
                }
            }
        }
    }

    private func stopTransportMonitor() {
        transportMonitorTask?.cancel()
        transportMonitorTask = nil
        pingStartedAt = nil
    }

    private func finishConnectionStartup() {
        connectionAttempt.finishConnecting(connectionAttempt.current)
        connectionReadyTimeoutTask?.cancel()
        connectionReadyTimeoutTask = nil
    }

    private var gateDetail: String {
        "opened=\(opened) ready=\(ready) recording=\(inputState.recording) canSend=\(canSendAudio()) \(inputState.diagnosticDetail)"
    }

    private var audioSummary: String {
        "queuedChunks=\(pcmQueuedChunks) queuedBytes=\(pcmQueuedBytes) sentChunks=\(pcmSentChunks) sentBytes=\(pcmSentBytes) outstandingPackets=\(sendQueue.packets.count) outstandingBytes=\(sendQueue.byteCount) pendingBytes=\(pendingPCM.count) droppedBytes=\(pcmDroppedBytes) sendErrors=\(pcmSendErrors) queueWait={\(queueWaitTiming.detail)} sendCompletion={\(sendCompletionTiming.detail)} callbackToHandler={\(sendCallbackTiming.detail)} events=\(receivedEvents)"
    }

    private func logFlow(_ title: String, _ detail: String = "") {
        DebugLogStore.logTranslation(title, detail: "session=\(diagnosticID) attempt=\(connectionAttempt.current) \(detail)")
    }

    private func logReceived(_ type: String, detail: String) {
        let count = (receivedEvents[type] ?? 0) + 1
        receivedEvents[type] = count
        // Keep exported logs bounded during long translations; never dump transcripts/audio.
        if count == 1 || count.isMultiple(of: 50) || ["ready", "warn", "error", "speech_started", "speech_stopped", "service_disconnected", "stopped", "translation_completed"].contains(type) {
            logFlow("WS received", "type=\(type) count=\(count) \(detail) \(gateDetail)")
        }
    }

    private func handleSocketFailure(_ error: Error, task: URLSessionWebSocketTask, operation: String) {
        // The receive and send callbacks can both report the same transport failure.
        guard webSocketTask === task, receiveLoopRunning else { return }
        logFlow("socket failed", "operation=\(operation) error=\(error.localizedDescription) closeCode=\(task.closeCode.rawValue) \(audioSummary)")
        close()
        callback?.onError(error.localizedDescription)
        callback?.onClosed()
    }

    // MARK: - PCM Playback

    private func startGlassesRouteRetry() {
        guard glassesRouteRetryTask == nil else { return }
        logFlow("glasses playback waiting", "chunks=\(waitingGlassesAudio.chunks.count) bytes=\(waitingGlassesAudio.byteCount) timeout=10s\n\(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
        callback?.onGlassesPlaybackStateChanged(.waiting)
        glassesRouteRetryTask = Task { @MainActor [weak self] in
            var lastRouteRefresh: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, self.speechPlaybackEnabled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.waitingGlassesAudio.timedOut(now: now) {
                    self.failGlassesPlayback(reason: "route timeout")
                    return
                }
                // Do not repeatedly reconfigure a route that is already playing.
                if !GlassesAudioRouteController.isOutputOnBluetooth, now - lastRouteRefresh >= 1 {
                    lastRouteRefresh = now
                    _ = self.prepareGlassesSpeechOutput()
                }
                guard GlassesAudioRouteController.isOutputOnBluetooth else { continue }
                while let data = self.waitingGlassesAudio.chunks.first {
                    guard self.playPCM(data, route: .glasses, requiresBluetoothOutput: true) else { break }
                    self.waitingGlassesAudio.removeFirst()
                }
                if self.waitingGlassesAudio.chunks.isEmpty {
                    self.glassesRouteRetryTask = nil
                    self.logFlow("glasses playback resumed")
                    self.callback?.onGlassesPlaybackStateChanged(.playing)
                    return
                }
            }
        }
    }

    private func failGlassesPlayback(reason: String) {
        logFlow("glasses playback unavailable", "reason=\(reason) droppedChunks=\(waitingGlassesAudio.chunks.count) droppedBytes=\(waitingGlassesAudio.byteCount)\n\(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
        glassesRouteRetryTask?.cancel()
        glassesRouteRetryTask = nil
        waitingGlassesAudio.reset()
        callback?.onGlassesPlaybackStateChanged(.unavailable)
    }

    @discardableResult
    private func playPCM(_ data: Data, route: PlaybackRoute, requiresBluetoothOutput: Bool = false) -> Bool {
        guard speechPlaybackEnabled, !data.isEmpty else { return false }
        ensurePlaybackEngine(route: route)
        if requiresBluetoothOutput, !GlassesAudioRouteController.isOutputOnBluetooth {
            logFlow("glasses playback blocked", GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)
            stopPlayback(clearWaitingAudio: false)
            print("[RealtimeTranslation] glasses playback blocked: output is not Bluetooth")
            return false
        }
        guard let playerNode, let playbackFormat else { return false }

        guard let buffer = TranslationPCMPlayback.makeBuffer(from: data, format: playbackFormat) else {
            print("[RealtimeTranslation] invalid playback PCM bytes=\(data.count) format=\(playbackFormat)")
            return false
        }
        let suppressesInput = TranslationAudioInputState.shouldSuppressPlayback(
            phoneMicrophone: phoneMicrophoneCaptureEnabled,
            bluetoothOutput: GlassesAudioRouteController.isOutputOnBluetooth
        )
        let playbackID = inputState.playbackScheduled(
            duration: Double(buffer.frameLength) / playbackFormat.sampleRate,
            suppressesInput: suppressesInput, now: Date()
        )
        if suppressesInput {
            pcmDroppedBytes += pendingPCM.count
            pendingPCM.removeAll(keepingCapacity: true)
        }
        startPlaybackMonitor()
        let generation = playbackGeneration
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                self.inputState.playbackCompleted(playbackID, now: Date())
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
        playbackChunks += 1
        if playbackChunks == 1 || playbackChunks.isMultiple(of: 50) {
            logFlow("speech scheduled", "chunks=\(playbackChunks) bytes=\(data.count) route=\(route) suppressesInput=\(suppressesInput) engineRunning=\(audioEngine?.isRunning ?? false)\n\(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
        }
        return true
    }

    private func startPlaybackMonitor() {
        guard playbackMonitorTask == nil else { return }
        playbackMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                // Lost dataPlayedBack callbacks must not mute the rest of a session.
                // Stop the old output before releasing its echo gate.
                if self.inputState.hasExpiredPlayback(now: Date()) {
                    self.logFlow("playback completion timeout", self.gateDetail)
                    self.stopPlayback(clearWaitingAudio: false)
                    return
                }
            }
        }
    }

    private func ensurePlaybackEngine(route: PlaybackRoute) {
        // Reapplying category/override/preferredInput on every TTS packet repeatedly
        // switches A2DP/HFP/receiver and can interrupt the audio we just scheduled.
        // Stopping the mic alone must not discard already scheduled translation audio.
        if audioEngine?.isRunning == true, playerNode != nil,
           activePlaybackRoute == route,
           (!phoneMicrophoneCaptureEnabled || playbackUsesPhoneMicrophone) { return }
        stopPlayback(clearWaitingAudio: false)
        applyPlaybackRoute(route)
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
            activePlaybackRoute = route
            playbackUsesPhoneMicrophone = phoneMicrophoneCaptureEnabled
        } catch {
            logFlow("playback engine failed", error.localizedDescription)
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
                try GlassesAudioRouteController.activate(phoneMicrophoneCaptureEnabled ? .phoneMicrophoneAndPlayback : .playback)
            case .default:
                if phoneMicrophoneCaptureEnabled {
                    try GlassesAudioRouteController.activate(.phoneMicrophoneAndPlayback)
                } else if GlassesAudioRouteController.glassesConnected {
                    try GlassesAudioRouteController.activate(.playback)
                } else {
                    try session.setCategory(.playback, mode: .default, options: [])
                    try session.setActive(true)
                }
            }
        } catch {
            logFlow("playback route failed", "route=\(route) error=\(error.localizedDescription)")
            print("[RealtimeTranslation] apply route \(route) failed: \(error.localizedDescription)")
        }
    }

    private func stopPlayback(clearWaitingAudio: Bool = true) {
        // Engine rebuilds preserve waiting chunks; explicit stop/close discards them.
        if clearWaitingAudio {
            glassesRouteRetryTask?.cancel()
            glassesRouteRetryTask = nil
            waitingGlassesAudio.reset()
        }
        playbackMonitorTask?.cancel()
        playbackMonitorTask = nil
        playbackGeneration &+= 1
        inputState.playbackCancelled(now: Date())
        playerNode?.stop()
        audioEngine?.stop()
        if let playerNode, let audioEngine {
            audioEngine.detach(playerNode)
        }
        playerNode = nil
        audioEngine = nil
        playbackFormat = nil
        activePlaybackRoute = nil
        playbackUsesPhoneMicrophone = false
        playbackChunks = 0
    }

    // MARK: - Helpers

    /// Backend diagnostics remain in the log; notices follow the app language.
    static func localizedServiceError(_ message: String, disconnected: Bool) -> String {
        if message.contains("连接翻译服务失败") {
            return L10n.t(
                "翻译服务暂不可用，请稍后重试。若持续失败，请联系客服。",
                "The translation service is temporarily unavailable. Please try again later. If this continues, contact support."
            )
        }
        if L10n.usesEnglish, message.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
            return disconnected
                ? "The translation service disconnected. Please try again."
                : "The translation service reported an error. Please try again later."
        }
        return message
    }

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
