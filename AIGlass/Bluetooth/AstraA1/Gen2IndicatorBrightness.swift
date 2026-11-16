import Foundation

enum IndicatorBrightnessLevel: UInt8, CaseIterable {
    case low = 0
    case medium = 1
    case high = 2
}

/// V1.1 sends levels, never the device's internal PWM percentages.
enum Gen2IndicatorBrightnessProtocol {
    struct Response: Equatable {
        let status: UInt8
        let level: IndicatorBrightnessLevel
    }

    static func query() -> Data {
        packet(command: "getledbri0", payload: [])
    }

    static func set(_ level: IndicatorBrightnessLevel) -> Data {
        packet(command: "setledbri0", payload: [level.rawValue])
    }

    static func parseResponse(_ data: Data) -> Response? {
        let bytes = Array(data)
        guard bytes.count == 14,
              Array(bytes.prefix(10)) == Array("ledbrirsp0".utf8),
              bytes[10] == 2, bytes[11] == 0,
              let level = IndicatorBrightnessLevel(rawValue: bytes[13]) else { return nil }
        return Response(status: bytes[12], level: level)
    }

    private static func packet(command: String, payload: [UInt8]) -> Data {
        Data(Array(command.utf8) + [UInt8(payload.count), 0] + payload)
    }
}

/// Only device replies confirm a level. Requests have no wire transaction ID,
/// so never overlap query/set requests or retry an accepted write.
struct Gen2IndicatorBrightnessState: Equatable {
    static let retryInterval: TimeInterval = 0.25
    static let maximumWriteAttempts = 8
    static let responseTimeout: TimeInterval = 3

    enum Request: Equatable {
        case query
        case set(IndicatorBrightnessLevel)

        var packet: Data {
            switch self {
            case .query: return Gen2IndicatorBrightnessProtocol.query()
            case .set(let level): return Gen2IndicatorBrightnessProtocol.set(level)
            }
        }
    }

    enum Failure: Equatable {
        case invalidParameter
        case storageFailed
        case rejected(UInt8)
        case differentLevel
        case sendFailed
        case timeout
    }

    struct Pending: Equatable {
        let id: UUID
        let request: Request
        var writeAttempts = 0
        var awaitingResponse = false
    }

    struct Result: Equatable {
        let id: UUID
        let request: Request
        let failure: Failure?
    }

    private(set) var level: IndicatorBrightnessLevel?
    private(set) var pending: Pending?
    private(set) var result: Result?
    var isPending: Bool { pending != nil }

    mutating func begin(_ request: Request) -> UUID? {
        guard pending == nil else { return nil }
        let id = UUID()
        pending = Pending(id: id, request: request)
        result = nil
        return id
    }

    @discardableResult
    mutating func recordWrite(id: UUID, accepted: Bool) -> Bool {
        guard var current = pending, current.id == id, !current.awaitingResponse,
              current.writeAttempts < Self.maximumWriteAttempts else { return false }
        current.writeAttempts += 1
        current.awaitingResponse = accepted
        pending = current
        return true
    }

    @discardableResult
    mutating func receive(_ response: Gen2IndicatorBrightnessProtocol.Response) -> Bool {
        // Ignore a delayed response while the next request has not been sent.
        if let pending, !pending.awaitingResponse { return false }
        level = response.level
        guard let current = pending else { return true }
        let failure: Failure?
        switch response.status {
        case 0:
            if case .set(let requested) = current.request, requested != response.level {
                failure = .differentLevel
            } else {
                failure = nil
            }
        case 1: failure = .invalidParameter
        case 2: failure = .storageFailed
        default: failure = .rejected(response.status)
        }
        return finish(id: current.id, failure: failure)
    }

    @discardableResult
    mutating func finish(id: UUID, failure: Failure?) -> Bool {
        guard let current = pending, current.id == id else { return false }
        result = Result(id: id, request: current.request, failure: failure)
        pending = nil
        return true
    }

    mutating func reset() {
        self = Self()
    }
}
