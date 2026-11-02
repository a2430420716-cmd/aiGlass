import Foundation

/// Coalesces page refreshes and file-change notifications on sensitive Gen1 firmware.
/// A missing reply delays the next request, but never blocks a session permanently.
struct Gen1BackgroundQueryGate {
    enum Query: Hashable { case battery, fileList }

    private var lastSent: [Query: TimeInterval] = [:]
    private var awaitingReplyUntil: [Query: TimeInterval] = [:]
    private let minimumInterval: TimeInterval = 5
    private let replyTimeout: TimeInterval = 10

    func delay(for query: Query, at now: TimeInterval, freshContent: Bool = false) -> TimeInterval {
        let recentUntil = freshContent ? now : (lastSent[query].map { $0 + minimumInterval } ?? now)
        return max(0, max(recentUntil, awaitingReplyUntil[query] ?? now) - now)
    }

    mutating func sent(_ query: Query, at now: TimeInterval) {
        lastSent[query] = now
        awaitingReplyUntil[query] = now + replyTimeout
    }

    mutating func received(_ query: Query, at now: TimeInterval) {
        guard lastSent[query] != nil else { return }
        // File lists can span notifications. Leave a short quiet period before
        // resetting the accumulator for a follow-up file-change query.
        awaitingReplyUntil[query] = query == .fileList ? now + 0.5 : now
    }

    mutating func reset() {
        lastSent.removeAll()
        awaitingReplyUntil.removeAll()
    }
}
