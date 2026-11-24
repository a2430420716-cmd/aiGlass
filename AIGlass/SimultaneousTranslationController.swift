import AVFoundation
import Combine
import Foundation

/// 同声传译页面控制器：对齐安卓 `SimultaneousTranslationActivity`。
@MainActor
final class SimultaneousTranslationController: ObservableObject {
    @Published var sourceLanguage = "中文"
    @Published var targetLanguage = "英文"
    @Published var sourceText = ""
    @Published var targetText = ""
    @Published var socketStatus = L10n.t("正在连接翻译服务...", "Connecting translation service...")
    @Published var isRecording = false
    @Published private(set) var isConnecting = false
    var hasActiveRecordingRequest: Bool { isRecording || isConnecting }
    @Published var hasRecorded = false
    @Published private(set) var glassesSoundEnabled = SimultaneousTranslationRecordStore.glassesSoundEnabled
    @Published var alertMessage: String?
    @Published var confirmExitWhileRecording = false

    private var translationManager: RealtimeTranslationManager?
    private let microphoneCapture = TranslationMicrophoneCapture()
    private var token: String = ""
    private var isActive = false
    private var permissionGeneration = 0
    private var speechChunksReceived = 0

    private var socketReady = false
    private var waitingSocketReady = false
    private var pendingStartRecord = false
    private var recordSaved = false
    private var recordStartedAt: Date?
    private var autoStopTask: Task<Void, Never>?

    private var sourceSegments: [String] = []
    private var targetSegments: [String] = []

    private let maxRecordDuration: TimeInterval = 3 * 60

    func start(token: String?) {
        isActive = true
        speechChunksReceived = 0
        DebugLogStore.logTranslation("simultaneous playback preference", detail: "enabled=\(glassesSoundEnabled)")
        translationManager?.close()
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let manager = RealtimeTranslationManager(callback: self)
        translationManager = manager
        manager.setSpeechPlaybackEnabled(glassesSoundEnabled)
        manager.setAutoPlayIncomingSpeech(false)
        connectSocketOnly()
    }

    func stop() {
        isActive = false
        permissionGeneration += 1
        autoStopTask?.cancel()
        if hasActiveRecordingRequest {
            stopRealtimeTranslation()
        } else {
            stopRecordingOnly()
            saveCurrentRecord()
        }
        translationManager?.close()
        translationManager = nil
        socketReady = false
    }

    func toggleGlassesSound() {
        // This is the preference for future speech, not a replay or route test.
        glassesSoundEnabled.toggle()
        DebugLogStore.logTranslation("simultaneous sound toggled", detail: "enabled=\(glassesSoundEnabled)\n\(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
        SimultaneousTranslationRecordStore.glassesSoundEnabled = glassesSoundEnabled
        translationManager?.setSpeechPlaybackEnabled(glassesSoundEnabled)
        alertMessage = glassesSoundEnabled
            ? L10n.t("声音开关打开，可以通过眼镜听到译文", "Sound is on. Translation can be heard through the glasses.")
            : L10n.t("声音开关关闭，无法通过眼镜听到译文", "Sound is off. Translation cannot be heard through the glasses.")
    }

    func swapLanguages() {
        guard !hasActiveRecordingRequest else { return }
        let temp = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = temp
        reconnectForLanguageChange()
    }

    func updateSourceLanguage(_ language: String) {
        guard !hasActiveRecordingRequest else { return }
        sourceLanguage = language
        if sameLanguage(sourceLanguage, targetLanguage) {
            targetLanguage = TranslationLanguage.fallback(excluding: sourceLanguage)
        }
        reconnectForLanguageChange()
    }

    func updateTargetLanguage(_ language: String) {
        guard !hasActiveRecordingRequest else { return }
        targetLanguage = language
        if sameLanguage(sourceLanguage, targetLanguage) {
            sourceLanguage = TranslationLanguage.fallback(excluding: targetLanguage)
        }
        reconnectForLanguageChange()
    }

    /// 退出前先停录并尝试保存，再 dismiss。
    func prepareExitThen(_ dismiss: @escaping () -> Void) {
        confirmExitWhileRecording = false
        if isRecording {
            stopRealtimeTranslation()
        }
        stop()
        dismiss()
    }

    private func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        TranslationLanguage.code(forDisplayName: lhs) == TranslationLanguage.code(forDisplayName: rhs)
    }

    func toggleRecording() {
        if hasActiveRecordingRequest {
            stopRealtimeTranslation()
        } else {
            startRealtimeTranslation()
        }
    }

    func handleBackRequest(onConfirmExit: @escaping () -> Void) {
        if isRecording {
            confirmExitWhileRecording = true
        } else {
            onConfirmExit()
        }
    }

    func confirmExit() {
        confirmExitWhileRecording = false
    }

    // MARK: - Recording

    private func startRealtimeTranslation() {
        guard isActive, !hasActiveRecordingRequest else { return }
        guard !token.isEmpty else {
            alertMessage = L10n.t("未登录，无法开始同声传译", "Not signed in, cannot start interpretation")
            return
        }

        permissionGeneration += 1
        let permissionRequest = permissionGeneration
        Task {
            let granted = await requestMicrophonePermission()
            guard isActive, permissionGeneration == permissionRequest else { return }
            guard granted else {
                alertMessage = L10n.t("请开启麦克风权限后重试", "Enable microphone permission and try again")
                return
            }
            guard !hasActiveRecordingRequest else { return }

            maybeSaveCurrentRecord()
            translationManager?.resetSpeechPlaybackForTurn()
            speechChunksReceived = 0
            isConnecting = true
            hasRecorded = false
            recordSaved = false
            recordStartedAt = nil
            sourceText = ""
            targetText = ""
            sourceSegments.removeAll()
            targetSegments.removeAll()
            pendingStartRecord = true
            waitingSocketReady = !socketReady
            translationManager?.setSpeechPlaybackEnabled(glassesSoundEnabled)

            if !socketReady {
                socketStatus = L10n.t("正在连接翻译服务...", "Connecting translation service...")
                // Page entry may already be fetching the URL or awaiting ready.
                // Keep that attempt and its deadline when the user taps Start.
                if translationManager?.isConnecting != true {
                    translationManager?.connect(
                        sourceLanguage: TranslationLanguage.code(forDisplayName: sourceLanguage),
                        targetLanguage: TranslationLanguage.code(forDisplayName: targetLanguage),
                        token: token
                    )
                }
            } else {
                pendingStartRecord = false
                beginAudioRecord()
            }
        }
    }

    private func stopRealtimeTranslation() {
        let capturedAudio = isRecording
        translationManager?.markLocalRecordingStopped(reason: "simultaneous manual stop")
        translationManager?.finish()
        // 服务端结束当前 turn 后会关闭连接；下一次录音必须重新建连。
        socketReady = false
        stopRecordingOnly()
        isRecording = false
        hasRecorded = capturedAudio
        maybeSaveCurrentRecord()
        socketStatus = L10n.t("录音已结束", "Recording ended")
    }

    private func beginAudioRecord() {
        stopAudioEngine()
        guard translationManager?.markLocalRecordingStarted() == true else {
            socketStatus = L10n.t("翻译服务尚未就绪，请稍后再试", "Translation service not ready, try again later")
            isRecording = false
            isConnecting = false
            pendingStartRecord = false
            waitingSocketReady = false
            return
        }
        isConnecting = false
        isRecording = true
        do {
            translationManager?.setPhoneMicrophoneCaptureEnabled(true)
            let recordingManager = translationManager
            try microphoneCapture.start(label: "simultaneous", receive: { [weak self] pcm in
                guard let self, self.isActive, self.isRecording,
                      self.translationManager === recordingManager else { return false }
                return recordingManager?.sendPCM(pcm) ?? false
            }, failure: { [weak self] error in
                guard let self, self.isActive, self.isRecording,
                      self.translationManager === recordingManager else { return }
                self.stopRealtimeTranslation()
                self.alertMessage = error.localizedDescription
                self.socketStatus = error.localizedDescription
            })
            recordStartedAt = Date()
            socketStatus = L10n.t("正在录音翻译…", "Recording & translating…")
            scheduleAutoStop()
            print("[SimultaneousTranslation] audio record started")
        } catch {
            stopAudioEngine()
            translationManager?.markLocalRecordingStopped(reason: "simultaneous audio start failed")
            translationManager?.finish()
            socketReady = false
            alertMessage = error.localizedDescription
            isRecording = false
            pendingStartRecord = false
            waitingSocketReady = false
        }
    }

    private func stopRecordingOnly() {
        autoStopTask?.cancel()
        autoStopTask = nil
        if isRecording || pendingStartRecord || waitingSocketReady {
            translationManager?.markLocalRecordingStopped(reason: "simultaneous stopRecordingOnly")
        }
        stopAudioEngine()
        waitingSocketReady = false
        pendingStartRecord = false
        isConnecting = false
    }

    private func stopAudioEngine() {
        translationManager?.setPhoneMicrophoneCaptureEnabled(false)
        microphoneCapture.stop()
    }

    private func scheduleAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(maxRecordDuration * 1_000_000_000))
            guard !Task.isCancelled, isRecording else { return }
            stopRealtimeTranslation()
            alertMessage = L10n.t("已达到最长录音时长（3分钟）", "Reached max recording length (3 min)")
        }
    }

    private func connectSocketOnly() {
        guard !token.isEmpty else {
            socketStatus = L10n.t("未登录，无法连接翻译服务", "Not signed in, cannot connect translation service")
            return
        }
        guard !socketReady, !waitingSocketReady, !pendingStartRecord else { return }
        socketStatus = L10n.t("正在连接翻译服务...", "Connecting translation service...")
        translationManager?.connect(
            sourceLanguage: TranslationLanguage.code(forDisplayName: sourceLanguage),
            targetLanguage: TranslationLanguage.code(forDisplayName: targetLanguage),
            token: token
        )
    }

    private func reconnectForLanguageChange() {
        guard !hasActiveRecordingRequest else { return }
        socketReady = false
        translationManager?.close()
        let manager = RealtimeTranslationManager(callback: self)
        translationManager = manager
        manager.setSpeechPlaybackEnabled(glassesSoundEnabled)
        manager.setAutoPlayIncomingSpeech(false)
        connectSocketOnly()
    }

    private func maybeSaveCurrentRecord() {
        guard !hasActiveRecordingRequest else { return }
        saveCurrentRecord()
    }

    private func saveCurrentRecord() {
        guard !recordSaved else { return }
        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !target.isEmpty else { return }
        recordSaved = true
        let duration = Int64(((recordStartedAt.map { Date().timeIntervalSince($0) } ?? 0) * 1000).rounded())
        SimultaneousTranslationRecordStore.save(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            sourceText: source,
            targetText: target,
            durationMs: duration
        )
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Text merge (align Android)

    private func appendSourceText(_ text: String) {
        let full = appendIncrementalText(
            segments: &sourceSegments,
            text: text,
            language: TranslationLanguage.code(forDisplayName: sourceLanguage)
        )
        guard !full.isEmpty else { return }
        sourceText = full
    }

    private func appendTargetText(_ text: String) {
        let full = appendIncrementalText(
            segments: &targetSegments,
            text: text,
            language: TranslationLanguage.code(forDisplayName: targetLanguage)
        )
        guard !full.isEmpty else { return }
        targetText = full
    }

    private func appendIncrementalText(segments: inout [String], text: String, language: String) -> String {
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
}

extension SimultaneousTranslationController: RealtimeTranslationManager.Callback {
    func onReady() {
        guard isActive else { return }
        socketReady = true
        // 录音中再次 ready 表示上一轮处理完毕，别把提示退回「点击开始录音」。
        socketStatus = isRecording ? L10n.t("正在录音翻译…", "Recording & translating…") : L10n.t("翻译服务已就绪，点击下方按钮开始录音", "Translation service is ready. Tap the button below to start recording.")
        if pendingStartRecord, isConnecting, !microphoneCapture.isCapturing {
            waitingSocketReady = false
            pendingStartRecord = false
            beginAudioRecord()
        }
    }

    func onTaskStarted() {}

    func onGlassesPlaybackStateChanged(_ state: RealtimeTranslationManager.GlassesPlaybackState) {
        guard isActive, glassesSoundEnabled else { return }
        switch state {
        case .waiting:
            socketStatus = L10n.t("正在等待眼镜音频连接…", "Waiting for glasses audio…")
        case .playing:
            socketStatus = isRecording ? L10n.t("正在录音翻译…", "Recording & translating…") : L10n.t("正在播放译文语音…", "Playing translated speech")
        case .unavailable:
            translationManager?.resetSpeechPlaybackForTurn()
            socketStatus = L10n.t("眼镜音频暂不可用", "Glasses audio is temporarily unavailable")
            alertMessage = L10n.t("暂时无法通过眼镜播放译文，请检查系统音频输出后重试", "Translation audio could not play through the glasses. Check the audio output and try again.")
        }
    }

    func onTranscript(_ text: String) {
        appendSourceText(text)
    }

    func onTranscriptCompleted(_ text: String) {
        appendSourceText(text)
    }

    func onTranslation(_ text: String) {
        appendTargetText(text)
    }

    func onSpeech(_ data: Data) {
        speechChunksReceived += 1
        if speechChunksReceived == 1 || speechChunksReceived.isMultiple(of: 50) {
            DebugLogStore.logTranslation("simultaneous speech received", detail: "chunks=\(speechChunksReceived) bytes=\(data.count) active=\(isActive) playbackEnabled=\(glassesSoundEnabled)\n\(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
        }
        // Muted speech is discarded, including audio from a finished recording.
        guard isActive, glassesSoundEnabled else { return }
        _ = playSpeechOnGlasses(data)
    }

    @discardableResult
    private func playSpeechOnGlasses(_ data: Data) -> Bool {
        guard translationManager?.playSpeechOnGlasses(data, requiresBluetoothOutput: true) == true else {
            translationManager?.resetSpeechPlaybackForTurn()
            socketStatus = L10n.t("眼镜音频暂不可用", "Glasses audio is temporarily unavailable")
            alertMessage = L10n.t("暂时无法通过眼镜播放译文，请检查系统音频输出后重试", "Translation audio could not play through the glasses. Check the audio output and try again.")
            return false
        }
        return true
    }

    func onTranslationCompleted() {
        maybeSaveCurrentRecord()
    }

    func onTranslationFinal(_ text: String) {
        appendTargetText(text)
        maybeSaveCurrentRecord()
    }

    func onError(_ message: String) {
        guard isActive else { return }
        waitingSocketReady = false
        pendingStartRecord = false
        socketReady = false
        stopRecordingOnly()
        isRecording = false
        socketStatus = message.isEmpty ? L10n.t("翻译服务异常", "Translation service error") : message
        alertMessage = message
    }

    func onRecoverableError(_ message: String) {
        // 服务端仍在处理上一句：保持录音，只提示等待，等下一个 ready 自动继续。
        guard isActive, isRecording else { return }
        socketStatus = L10n.t("正在处理上一句翻译…", "Processing previous translation…")
        print("[SimultaneousTranslation] recoverable: \(message)")
    }

    func onClosed() {
        socketReady = false
        if !isRecording, alertMessage == nil {
            socketStatus = L10n.t("翻译服务已断开", "Translation service disconnected")
        }
    }
}
