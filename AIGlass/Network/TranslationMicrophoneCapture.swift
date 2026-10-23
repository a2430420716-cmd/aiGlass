@preconcurrency import AVFoundation
import Foundation

/// Keeps phone capture independent of WebSocket turns and translation playback.
/// Hardware audio stays at its native rate; only the uploaded PCM is 16 kHz.
@MainActor
final class TranslationMicrophoneCapture {
    private var engine: AVAudioEngine?
    private var processor: TranslationMicrophoneProcessor?
    private var observers: [NSObjectProtocol] = []
    private var monitor: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lifetime: UInt64 = 0
    private var active = false
    private var interrupted = false
    private var recovery = TranslationCaptureRecoveryState()
    private var receive: ((Data) -> Bool)?
    private var failure: ((Error) -> Void)?
    private var label = ""
    private var deliveredBytes = 0
    private var gatedBytes = 0

    /// Includes a temporary interruption/recovery, so duplicate ready cannot start a second mic.
    var isCapturing: Bool { active }

    func start(label: String, receive: @escaping (Data) -> Bool,
               failure: @escaping (Error) -> Void) throws {
        stop()
        self.label = label
        self.receive = receive
        self.failure = failure
        deliveredBytes = 0
        gatedBytes = 0
        active = true
        recovery = TranslationCaptureRecoveryState()
        do {
            try GlassesAudioRouteController.activate(.phoneMicrophoneAndPlayback)
            try installEngine()
            installObservers()
            startMonitor()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if active { log("capture stopped") }
        active = false
        lifetime &+= 1
        interrupted = false
        monitor?.cancel()
        monitor = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        discardEngine()
        receive = nil
        failure = nil
    }

    private func installEngine() throws {
        discardEngine()
        let next = AVAudioEngine()
        let input = next.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let nextProcessor = TranslationMicrophoneProcessor(inputFormat: format) else {
            throw captureError()
        }
        processor = nextProcessor
        engine = next
        let attempt = generation
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
            // Convert/copy inside the tap. AVAudioEngine reuses its buffer after return.
            guard let pcm = nextProcessor.convert(buffer) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.active, !self.interrupted,
                      self.generation == attempt else { return }
                if self.receive?(pcm) == true { self.deliveredBytes += pcm.count }
                else { self.gatedBytes += pcm.count }
            }
        }
        next.prepare()
        try next.start()
        log("capture engine started", detail: "inputFormat=\(format) uploadRate=16000 channels=1 bits=16")
    }

    private func discardEngine() {
        generation &+= 1
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        processor = nil
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let lifetime = self.lifetime
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.lifetime == lifetime else { return }
                self.scheduleRecovery(reason: "engine configuration changed")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.lifetime == lifetime else { return }
                self.scheduleRecovery(reason: "audio route changed")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: nil) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            let resume = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume)
            } ?? false
            Task { @MainActor [weak self] in
                guard let self, self.active, self.lifetime == lifetime else { return }
                if began {
                    self.interrupted = true
                    self.recoveryTask?.cancel()
                    self.recoveryTask = nil
                    self.engine?.pause()
                    self.log("capture interrupted")
                } else if resume {
                    self.interrupted = false
                    self.scheduleRecovery(reason: "interruption ended", force: true)
                } else {
                    self.fail(self.captureError())
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.lifetime == lifetime else { return }
                self.scheduleRecovery(reason: "media services reset", force: true)
            }
        })
    }

    private func startMonitor() {
        monitor = Task { @MainActor [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.active else { return }
                ticks += 1
                if ticks.isMultiple(of: 5) { self.log("capture progress") }
                guard !self.interrupted else { continue }
                if self.needsRecovery { self.scheduleRecovery(reason: "capture stalled or format changed") }
            }
        }
    }

    private var needsRecovery: Bool {
        guard let engine, let processor else { return true }
        let snapshot = processor.snapshot()
        return !engine.isRunning || snapshot.lastPCMAge >= 2 ||
            !engine.inputNode.outputFormat(forBus: 0).isEqual(processor.inputFormat)
    }

    private func scheduleRecovery(reason: String, force: Bool = false) {
        guard active, !interrupted, recoveryTask == nil else { return }
        recoveryTask = Task { @MainActor [weak self] in
            // Let iOS finish its route transition before reading the hardware format.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, self.active, !self.interrupted else { return }
            self.recoveryTask = nil
            guard force || self.needsRecovery else { return }
            guard self.recovery.allowRestart(now: ProcessInfo.processInfo.systemUptime) else {
                self.log("capture recovery exhausted", detail: "reason=\(reason)")
                self.fail(self.captureError())
                return
            }
            self.log("capture recovering", detail: "reason=\(reason)")
            do {
                try GlassesAudioRouteController.activate(.phoneMicrophoneAndPlayback)
                try self.installEngine()
            } catch {
                // A route can be temporarily unavailable. The monitor retries with a bound.
                self.log("capture recovery failed", detail: error.localizedDescription)
                self.discardEngine()
            }
        }
    }

    private func fail(_ error: Error) {
        let callback = failure
        stop()
        callback?(error)
    }

    private func captureError() -> NSError {
        NSError(domain: "TranslationMicrophoneCapture", code: 1, userInfo: [NSLocalizedDescriptionKey:
            L10n.t("麦克风录音中断，请重新开始录音", "Microphone recording was interrupted. Please start recording again.")])
    }

    private func log(_ title: String, detail: String = "") {
        let stats = processor?.snapshot().detail ?? "noCaptureEngine=true"
        DebugLogStore.logTranslation(title, detail: "capture=\(label) generation=\(generation) engineRunning=\(engine?.isRunning ?? false) interrupted=\(interrupted) acceptedBytes=\(deliveredBytes) gatedBytes=\(gatedBytes) \(stats) \(detail)\n\(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
    }
}

