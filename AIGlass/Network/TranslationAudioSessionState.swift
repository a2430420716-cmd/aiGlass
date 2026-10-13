import Foundation

/// Invalidates asynchronous URL lookups and socket callbacks when a session closes.
struct TranslationConnectionAttempt {
    private(set) var current: UInt64 = 0
    private var active = false

    mutating func begin() -> UInt64 {
        current &+= 1
        active = true
        return current
    }

    mutating func cancel() {
        current &+= 1
        active = false
    }

    func isCurrent(_ attempt: UInt64) -> Bool {
        active && current == attempt
    }
}

/// Local recording intent survives repeated server ready/turn-completed events.
struct TranslationAudioInputState {
    private(set) var recording = false
    private var backendProcessing = false
    private var lastStopAt: Date = .distantPast

    func canSendAudio(opened: Bool, ready: Bool) -> Bool {
        opened && ready && recording && !backendProcessing
    }

    mutating func start(opened: Bool, ready: Bool, now: Date) -> Bool {
        guard opened, ready else { return false }
        if recording { return !backendProcessing }
        guard now.timeIntervalSince(lastStopAt) >= 0.3 else { return false }
        recording = true
        backendProcessing = false
        return true
    }

    mutating func stop(now: Date) {
        recording = false
        backendProcessing = false
        lastStopAt = now
    }

    mutating func serviceReady() {
        backendProcessing = false
    }

    mutating func beginBackendProcessing() {
        backendProcessing = true
    }

    mutating func backendTurnFinished() {
        backendProcessing = false
    }

    mutating func close() {
        self = Self()
    }
}

/// Prevents duplicate ready events, stale ACKs and timeout tasks from opening a mic twice.
struct TranslationGlassesRecordingState {
    enum Phase: Equatable { case idle, waitingForSocket, waitingForDevice, recording, draining }
    private(set) var phase: Phase = .idle

    var shouldSendStart: Bool { phase == .waitingForSocket }
    var isWaitingForDevice: Bool { phase == .waitingForDevice }
    var hasSentCommand: Bool { [.waitingForDevice, .recording, .draining].contains(phase) }
    var acceptsAudio: Bool { phase == .recording || phase == .draining }

    mutating func begin() { phase = .waitingForSocket }

    @discardableResult
    mutating func commandSent() -> Bool {
        guard shouldSendStart else { return false }
        phase = .waitingForDevice
        return true
    }

    @discardableResult
    mutating func confirmStarted() -> Bool {
        guard phase == .waitingForDevice else { return false }
        phase = .recording
        return true
    }

    mutating func drain() {
        guard phase == .recording else { return }
        phase = .draining
    }

    mutating func reset() { phase = .idle }
}
