import Foundation

/// Inspect PCM16 little-endian without retaining microphone audio in diagnostics.
struct TranslationPCMStatistics {
    private(set) var bytes = 0
    private(set) var samples = 0
    private(set) var peak = 0
    private var energy = 0.0

    var durationMs: Int { samples * 1_000 / 16_000 }
    var rms: Double { samples > 0 ? sqrt(energy / Double(samples)) : 0 }

    mutating func append(_ pcm: Data) {
        bytes += pcm.count
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<(raw.count / 2) {
                let bits = UInt16(raw[index * 2]) | (UInt16(raw[index * 2 + 1]) << 8)
                let sample = Int(Int16(bitPattern: bits))
                peak = max(peak, abs(sample))
                energy += Double(sample) * Double(sample)
                samples += 1
            }
        }
    }

    var detail: String {
        "pcmBytes=\(bytes) durationMs=\(durationMs) peak=\(peak) rms=\(String(format: "%.1f", rms)) sampleRate=16000 channels=1"
    }
}

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
    private var playbackBuffers = 0
    private var playbackGuardUntil: Date = .distantPast

    func canSendAudio(opened: Bool, ready: Bool, now: Date = Date()) -> Bool {
        opened && ready && recording && !backendProcessing &&
            playbackBuffers == 0 && now >= playbackGuardUntil
    }

    var diagnosticDetail: String {
        "backendBusy=\(backendProcessing) playbackBuffers=\(playbackBuffers) playbackGuardMs=\(Int(max(0, playbackGuardUntil.timeIntervalSinceNow) * 1_000))"
    }

    mutating func playbackScheduled() {
        playbackBuffers += 1
    }

    mutating func playbackCompleted(now: Date) {
        guard playbackBuffers > 0 else { return }
        playbackBuffers -= 1
        if playbackBuffers == 0 { playbackGuardUntil = now.addingTimeInterval(0.5) }
    }

    mutating func playbackCancelled(now: Date) {
        if playbackBuffers > 0 { playbackGuardUntil = now.addingTimeInterval(0.5) }
        playbackBuffers = 0
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

/// One transport send at a time keeps stop after its PCM and bounds unsent audio.
/// Timestamps use system uptime, so wall-clock changes cannot mask a stalled send.
struct TranslationSocketSendQueue {
    enum Kind { case pcm, json(String) }
    struct Packet {
        let id: UInt64
        let kind: Kind
        let data: Data
        let queuedAt: TimeInterval
    }

    private(set) var packets: [Packet] = []
    private(set) var byteCount = 0
    private var nextID: UInt64 = 0
    private var sending = false
    static let maxPCMBytes = 160_000 // Five seconds of 16 kHz PCM16 mono.
    static let sendTimeout: TimeInterval = 15

    @discardableResult
    mutating func append(_ data: Data, kind: Kind, now: TimeInterval) -> Bool {
        guard packets.count < 128 else { return false }
        if case .pcm = kind {
            guard data.count <= Self.maxPCMBytes, byteCount <= Self.maxPCMBytes - data.count else { return false }
        }
        nextID &+= 1
        packets.append(Packet(id: nextID, kind: kind, data: data, queuedAt: now))
        byteCount += data.count
        return true
    }

    mutating func takeNext() -> Packet? {
        guard !sending, let packet = packets.first else { return nil }
        sending = true
        return packet
    }

    @discardableResult
    mutating func complete(_ id: UInt64) -> Bool {
        guard sending, packets.first?.id == id else { return false }
        byteCount -= packets.removeFirst().data.count
        sending = false
        return true
    }

    func oldestAge(now: TimeInterval) -> TimeInterval {
        packets.first.map { max(0, now - $0.queuedAt) } ?? 0
    }

    mutating func reset() {
        packets.removeAll()
        byteCount = 0
        sending = false
    }
}

/// A missing classic Bluetooth route must not silently play translation on phone.
struct TranslationGlassesPlaybackQueue {
    private(set) var chunks: [Data] = []
    private(set) var byteCount = 0
    private var waitingSince: TimeInterval?
    static let timeout: TimeInterval = 10

    mutating func append(_ data: Data, now: TimeInterval) -> Bool {
        guard chunks.count < 24, data.count <= 2_000_000,
              byteCount <= 2_000_000 - data.count else { return false }
        if waitingSince == nil { waitingSince = now }
        chunks.append(data)
        byteCount += data.count
        return true
    }

    mutating func removeFirst() {
        guard !chunks.isEmpty else { return }
        byteCount -= chunks.removeFirst().count
        if chunks.isEmpty { waitingSince = nil }
    }

    func timedOut(now: TimeInterval) -> Bool {
        waitingSince.map { now - $0 >= Self.timeout } ?? false
    }

    mutating func reset() { self = Self() }
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
