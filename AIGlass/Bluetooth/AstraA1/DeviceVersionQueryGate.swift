/// Limits automatic version queries to one attempt per connection session.
struct DeviceVersionQueryGate {
    struct Token: Equatable {
        fileprivate let id: UInt64
    }

    private var pendingToken: Token?
    private var automaticAttempted = false
    private var nextTokenID: UInt64 = 0

    /// Reserving delayed work does not consume the attempt until it starts.
    mutating func reserveAutomaticQuery() -> Token? {
        guard pendingToken == nil, !automaticAttempted else { return nil }
        nextTokenID += 1
        let token = Token(id: nextTokenID)
        pendingToken = token
        return token
    }

    /// Consume the attempt before sending so failed replies cannot cause a loop.
    mutating func claimAutomaticQuery(_ token: Token) -> Bool {
        guard pendingToken == token else { return false }
        pendingToken = nil
        automaticAttempted = true
        return true
    }

    mutating func cancelPendingQuery() {
        pendingToken = nil
    }

    /// A stale callback cannot cancel work reserved by a newer session.
    mutating func cancelPendingQuery(_ token: Token) {
        guard pendingToken == token else { return }
        pendingToken = nil
    }

    /// Explicit refreshes remain available after an automatic attempt is used.
    mutating func beginExplicitQuery() {
        pendingToken = nil
        automaticAttempted = true
    }

    mutating func reset() {
        pendingToken = nil
        automaticAttempted = false
        // Keep token IDs monotonic so callbacks from old sessions stay invalid.
    }
}
