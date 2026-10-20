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
    @Published var socketStatus = L10n.t("正在连接翻译服务...", "Connecting to translation service...")
    @Published var isRecording = false
    @Published var hasRecorded = false
    @Published var glassesSoundEnabled = SimultaneousTranslationRecordStore.glassesSoundEnabled
    @Published var alertMessage: String?
    @Published var confirmExitWhileRecording = false

    private var translationManager: RealtimeTranslationManager?
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var token: String = ""
    private var isActive = false
    private var permissionGeneration = 0

    private var socketReady = false
    private var waitingSocketReady = false
    private var pendingStartRecord = false
    private var recordSaved = false
    private var recordStartedAt: Date?
    private var autoStopTask: Task<Void, Never>?

    private var sourceSegments: [String] = []
    private var targetSegments: [String] = []

    private let maxRecordDuration: TimeInterval = 3 * 60
    private let targetSampleRate: Double = 16_000

    func start(token: String?) {
        isActive = true
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
        if isRecording {
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
        if !glassesSoundEnabled, translationManager?.prepareGlassesSpeechOutput() != true {
            alertMessage = L10n.t("眼镜蓝牙音频未连接，请在系统蓝牙设置中连接眼镜音频后再开启播报", "Glasses Bluetooth audio is unavailable. Connect the glasses audio in Bluetooth settings before enabling playback.")
            return
        }
        glassesSoundEnabled.toggle()
        SimultaneousTranslationRecordStore.glassesSoundEnabled = glassesSoundEnabled
        translationManager?.setSpeechPlaybackEnabled(glassesSoundEnabled)
        alertMessage = glassesSoundEnabled
            ? L10n.t("声音开关打开，可以通过眼镜听到译文", "Sound on — hear translations through glasses")
            : L10n.t("声音开关关闭，无法通过眼镜听到译文", "Sound off — cannot hear translations through glasses")
    }

    func swapLanguages() {
        guard !isRecording else { return }
        let temp = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = temp
        reconnectForLanguageChange()
    }

    func updateSourceLanguage(_ language: String) {
        guard !isRecording else { return }
        sourceLanguage = language
        if sameLanguage(sourceLanguage, targetLanguage) {
            targetLanguage = TranslationLanguage.fallback(excluding: sourceLanguage)
        }
        reconnectForLanguageChange()
    }

    func updateTargetLanguage(_ language: String) {
        guard !isRecording else { return }
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
        if isRecording {
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
        guard isActive, !isRecording else { return }
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
                alertMessage = L10n.t("请开启麦克风权限后重试", "Enable microphone access and try again")
                return
            }
            guard !isRecording else { return }

            maybeSaveCurrentRecord()
            isRecording = true
            hasRecorded = false
            recordSaved = false
            recordStartedAt = Date()
            sourceText = ""
            targetText = ""
            sourceSegments.removeAll()
            targetSegments.removeAll()
            pendingStartRecord = true
            waitingSocketReady = !socketReady
            translationManager?.setSpeechPlaybackEnabled(glassesSoundEnabled)

            if !socketReady {
                socketStatus = L10n.t("正在连接翻译服务...", "Connecting to translation service...")
                translationManager?.connect(
                    sourceLanguage: TranslationLanguage.code(forDisplayName: sourceLanguage),
                    targetLanguage: TranslationLanguage.code(forDisplayName: targetLanguage),
                    token: token
                )
            } else {
                pendingStartRecord = false
                beginAudioRecord()
            }
        }
    }

    private func stopRealtimeTranslation() {
        translationManager?.markLocalRecordingStopped(reason: "simultaneous manual stop")
        translationManager?.finish()
        // 服务端结束当前 turn 后会关闭连接；下一次录音必须重新建连。
        socketReady = false
        stopRecordingOnly()
        isRecording = false
        hasRecorded = true
        maybeSaveCurrentRecord()
        socketStatus = L10n.t("录音已结束", "Recording ended")
    }

    private func beginAudioRecord() {
        stopAudioEngine()
        guard translationManager?.markLocalRecordingStarted() == true else {
            socketStatus = L10n.t("翻译服务尚未就绪，请稍后再试", "Translation service not ready, try again later")
            isRecording = false
            pendingStartRecord = false
            waitingSocketReady = false
            return
        }
        do {
            translationManager?.setPhoneMicrophoneCaptureEnabled(true)
            try GlassesAudioRouteController.activate(.playAndRecord)
            let session = AVAudioSession.sharedInstance()
            if let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(microphone)
            }
            try session.setPreferredSampleRate(targetSampleRate)

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: true
            ) else {
                throw NSError(domain: "SimultaneousTranslation", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: L10n.t("音频格式初始化失败", "Failed to initialize audio format")])
            }

            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            self.converter = converter
            self.audioEngine = engine

            let bufferSize: AVAudioFrameCount = 1024
            input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
                self?.handleCapturedBuffer(buffer, targetFormat: targetFormat)
            }
            try engine.start()
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

    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard isRecording, let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var supplied = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard !supplied else {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        if let error {
            print("[SimultaneousTranslation] convert failed: \(error.localizedDescription)")
            return
        }
        guard converted.frameLength > 0,
              let channels = converted.int16ChannelData else { return }
        let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: channels[0], count: byteCount)
        let recordingManager = translationManager
        Task { @MainActor [weak self] in
            guard let self, self.isActive, self.isRecording,
                  self.translationManager === recordingManager else { return }
            _ = recordingManager?.sendPCM(data)
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
    }

    private func stopAudioEngine() {
        translationManager?.setPhoneMicrophoneCaptureEnabled(false)
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        converter = nil
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
        socketStatus = L10n.t("正在连接翻译服务...", "Connecting to translation service...")
        translationManager?.connect(
            sourceLanguage: TranslationLanguage.code(forDisplayName: sourceLanguage),
            targetLanguage: TranslationLanguage.code(forDisplayName: targetLanguage),
            token: token
        )
    }

    private func reconnectForLanguageChange() {
        guard !isRecording else { return }
        socketReady = false
        translationManager?.close()
        let manager = RealtimeTranslationManager(callback: self)
        translationManager = manager
        manager.setSpeechPlaybackEnabled(glassesSoundEnabled)
        manager.setAutoPlayIncomingSpeech(false)
        connectSocketOnly()
    }

    private func maybeSaveCurrentRecord() {
        guard !isRecording else { return }
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
        socketStatus = isRecording ? L10n.t("正在录音翻译…", "Recording & translating…") : L10n.t("翻译服务已就绪，点击下方按钮开始录音", "Ready — tap below to start recording")
        if waitingSocketReady, isRecording, audioEngine == nil {
            waitingSocketReady = false
            pendingStartRecord = false
            beginAudioRecord()
        } else if pendingStartRecord, isRecording, audioEngine == nil {
            pendingStartRecord = false
            beginAudioRecord()
        }
    }

    func onTaskStarted() {}

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
        guard isActive, glassesSoundEnabled else { return }
        guard translationManager?.playSpeechOnGlasses(data, requiresBluetoothOutput: true) == true else {
            glassesSoundEnabled = false
            SimultaneousTranslationRecordStore.glassesSoundEnabled = false
            translationManager?.setSpeechPlaybackEnabled(false)
            alertMessage = L10n.t("眼镜音频不可用，已关闭眼镜播报，请检查系统蓝牙音频连接", "Glasses audio is unavailable. Playback has been disabled. Check the Bluetooth audio connection.")
            return
        }
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
        if !isRecording {
            socketStatus = L10n.t("翻译服务已断开", "Translation service disconnected")
        }
    }
}
