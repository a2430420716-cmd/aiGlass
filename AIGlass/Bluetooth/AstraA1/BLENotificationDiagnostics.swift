import Foundation

/// Formats callback evidence only. Raw bytes must never be fed back into a protocol parser.
nonisolated enum BLENotificationDiagnostics {
    static let maximumHexBytes = 64

    struct Record {
        let title: String
        let detail: String
    }

    private static let mediaCommands = ["aivoicedat", "trslatedat", "imgrecdata"]

    static func format(
        data: Data?,
        peripheralID: String,
        characteristicID: String,
        context: String,
        error: String?
    ) -> Record {
        var lines = [
            "stage=RAW/before framing",
            "peripheral=\(peripheralID) characteristic=\(characteristicID)",
            "context=\(context)"
        ]
        if let error {
            // CBCharacteristic.value may still contain an earlier successful value.
            // An error callback must not present those cached bytes as a new packet.
            lines.append("value=ignored rawBytes=0 cachedValueBytes=\(data?.count ?? 0)")
            lines.append("error=\(error)")
        } else if let data {
            lines.append("value=received rawBytes=\(data.count)")
            // Redact the entire callback even if it contains a control frame followed
            // by a media frame. This is conservative log redaction, not frame parsing.
            let media = mediaCommands.filter { data.range(of: Data($0.utf8)) != nil }
            if !media.isEmpty {
                lines.append("media=\(media.joined(separator: ",")) payload=omitted omittedBytes=\(data.count)")
            } else {
                let bytes = data.prefix(maximumHexBytes)
                let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                lines.append("hex=\(hex.isEmpty ? "<empty>" : hex)")
                lines.append("omittedBytes=\(data.count - bytes.count)")
            }
        } else {
            lines.append("value=nil rawBytes=0")
        }
        return Record(title: "RAW · before framing", detail: lines.joined(separator: "\n"))
    }
}

/// The connection owner resets this budget on a new connection. It is deliberately
/// independent of the log store so queued logging cannot change callback accounting.
nonisolated struct BLERawDiagnosticBudget {
    enum Decision: Equatable {
        case record
        case limitReached
        case suppress
    }

    let limit: Int
    private var recorded = 0
    private var reportedLimit = false

    init(limit: Int = 256) {
        self.limit = max(0, limit)
    }

    mutating func record() -> Decision {
        if recorded < limit {
            recorded += 1
            return .record
        }
        if !reportedLimit {
            reportedLimit = true
            return .limitReached
        }
        return .suppress
    }

    mutating func reset() {
        recorded = 0
        reportedLimit = false
    }
}
