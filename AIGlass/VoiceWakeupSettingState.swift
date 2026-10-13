/// Tracks the Android getwakeup0/setwakeup0 flow, whose wakeuprsp0 reply has no request ID.
/// Before the first reply, state is unknown rather than an implicit “off”.
struct VoiceWakeupSettingState {
    enum Phase: Equatable {
        case unknown, querying, ready, setting, queryFailed
    }

    enum ResponseEffect: Equatable {
        case none
        case updated
        case failed(status: UInt8)
    }

    private(set) var phase: Phase = .unknown
    private(set) var enabled: Bool?
    private(set) var generation = 0
    private(set) var target: Bool?

    var canChange: Bool { phase == .ready && enabled != nil }
    var isSetting: Bool { phase == .setting }

    mutating func reset() {
        generation += 1
        phase = .unknown
        enabled = nil
        target = nil
    }

    /// The token also cancels a delayed query when a write or a new session starts.
    mutating func beginQuery() -> Int? {
        guard !isSetting else { return nil }
        generation += 1
        phase = .querying
        return generation
    }

    @discardableResult
    mutating func queryTimedOut(generation token: Int) -> Bool {
        guard token == generation, phase == .querying else { return false }
        generation += 1
        phase = .queryFailed
        enabled = nil
        return true
    }

    mutating func beginSet(_ requested: Bool) -> Int? {
        guard canChange, enabled != requested else { return nil }
        generation += 1
        target = requested
        phase = .setting
        return generation
    }

    /// Android waits five seconds, reports failure, then queries after 250 ms.
    /// A missing ACK never triggers another set command.
    mutating func setTimedOut(generation token: Int) -> Bool {
        guard token == generation, isSetting else { return false }
        generation += 1
        target = nil
        phase = .unknown
        return true
    }

    mutating func sendFailed(generation token: Int) -> Bool {
        guard token == generation, isSetting else { return false }
        generation += 1
        target = nil
        phase = enabled == nil ? .unknown : .ready
        return true
    }

    mutating func receive(status: UInt8, enabled reported: Bool) -> ResponseEffect {
        let wasSetResponse = target != nil
        generation += 1
        enabled = reported
        target = nil
        phase = .ready
        // Match Android: the enabled byte always supplies the device's current state;
        // status is a user-facing result only when a set request is pending.
        guard wasSetResponse else { return .none }
        return status == 0 ? .updated : .failed(status: status)
    }
}
