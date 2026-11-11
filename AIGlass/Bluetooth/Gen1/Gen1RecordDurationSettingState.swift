import Foundation

/// SET replies may contain a status byte rather than the selected profile.
/// Only a separate QUERY can confirm what the glasses actually stored.
struct Gen1RecordDurationSettingState {
    enum Outcome: Equatable {
        case confirmed(seconds: Int)
        case different(requested: Int, actual: Int)
        case unconfirmed(seconds: Int)
    }

    struct Result: Equatable {
        let token: Int
        let outcome: Outcome
    }

    private(set) var token = 0
    private(set) var requestedSeconds: Int?
    private(set) var confirmedSeconds: Int?
    private(set) var result: Result?
    private var verificationQuerySent = false
    private var verificationSeconds: Int?

    var isPending: Bool { requestedSeconds != nil }

    mutating func beginSet(seconds: Int) -> Int? {
        guard DeviceCapabilities.allRecordDurationSeconds.contains(seconds) else { return nil }
        token += 1
        requestedSeconds = seconds
        verificationQuerySent = false
        verificationSeconds = nil
        result = nil
        return token
    }

    mutating func beginVerificationQuery(token expected: Int) -> Bool {
        guard token == expected, isPending else { return false }
        verificationQuerySent = true
        return true
    }

    /// Returns an actual device duration, never the value of a SET ACK.
    mutating func receive(command: UInt8, payload: Data) -> Int? {
        guard command == Gen1Commands.recordDurationQuery,
              payload.count == 1, let profile = payload.first,
              Int(profile) < DeviceCapabilities.allRecordDurationSeconds.count else { return nil }
        if isPending, !verificationQuerySent { return nil }
        let seconds = DeviceCapabilities.allRecordDurationSeconds[Int(profile)]
        confirmedSeconds = seconds
        guard let requestedSeconds else { return seconds }
        verificationSeconds = seconds
        if seconds == requestedSeconds {
            result = Result(token: token, outcome: .confirmed(seconds: seconds))
            self.requestedSeconds = nil
        }
        return seconds
    }

    @discardableResult
    mutating func finish(token expected: Int) -> Bool {
        guard token == expected, let requestedSeconds else { return false }
        let outcome: Outcome
        if let actual = verificationSeconds {
            outcome = .different(requested: requestedSeconds, actual: actual)
        } else {
            outcome = .unconfirmed(seconds: requestedSeconds)
        }
        result = Result(token: token, outcome: outcome)
        self.requestedSeconds = nil
        return true
    }

    mutating func reset() {
        token += 1
        requestedSeconds = nil
        confirmedSeconds = nil
        result = nil
        verificationQuerySent = false
        verificationSeconds = nil
    }
}
