import Foundation

/// Splits one characteristic update into the same 10-byte command / LE16-length
/// frames used by Android's `extractNotificationFrames`.
///
/// This deliberately has no cross-notification buffer. Some firmware truncates a
/// notification at the ATT MTU and requires reading the characteristic again; that
/// read is a fresh full packet, not the continuation of the notification. Incomplete
/// tails are therefore returned unchanged so existing command-specific read fallback
/// remains responsible for them. Never feed one returned frame back into this splitter.
enum AstraNotificationFramer {
    /// The wire length is UInt16. No data is retained between characteristic updates.
    static let maximumPayloadLength = Int(UInt16.max)

    private static let knownCommands: Set<String> = [
        "getdevinfo", "hasnewfile", "toopenwifi", "getworkpat", "getalgoinf",
        "dllupdrsp0", "dllprogres", "deletefile", "closewifi", "closewifi0",
        "wificonfig", "otaprogres", "otaprogre", "batteryntf", "chargestat", "devstatus0",
        "actionrsp0", "guideevt00", "eqmodersp0", "vidresrsp0", "weardetrsp",
        "testresult", "takephoto0", "startvideo", "stopvideo0", "imgrecdata",
        "imgrecrsp0", "aivoicests", "aivoicedat", "aivoicetur", "aivsilrsp0",
        "wakeuprsp0", "trslatests", "trslatedat"
    ]

    static func frames(in data: Data) -> [Data] {
        let bytes = Array(data)
        var frames: [Data] = []
        var offset = 0
        while bytes.count - offset >= 12 {
            if let status = legacyCloseWifiStatus(in: bytes, at: offset) {
                // Some G5T71 firmware omits the tenth header padding byte only for
                // closewifi ACKs. Normalize that exact 12-byte wire format so the
                // existing status handler continues to consume standard frames.
                var frame = Data("closewifi".utf8)
                frame.append(contentsOf: [0, 1, 0, status])
                frames.append(frame)
                offset += 12
                continue
            }
            guard let command = command(in: bytes, at: offset) else {
                guard let next = nextCompleteKnownFrame(in: bytes, after: offset) else { break }
                offset = next
                continue
            }

            let payloadLength = length(in: bytes, at: offset)
            let remaining = bytes.count - offset
            // Preserve the existing iOS compatibility path: devstatus0 occasionally
            // reports zero length while still including its one-byte runtime status.
            let frameLength = command == "devstatus0" && payloadLength == 0
                && remaining >= 13 && bytes[offset + 12] <= 6
                ? 13 : 12 + payloadLength

            if remaining >= frameLength {
                frames.append(Data(bytes[offset..<(offset + frameLength)]))
                offset += frameLength
                continue
            }

            // Android supports 12-byte legacy concatenations when the length field
            // does not describe a payload. Validate every header before applying that
            // fallback, so an ordinary truncated text response is not split blindly.
            if payloadLength > 0, remaining.isMultiple(of: 12),
               stride(from: offset, to: bytes.count, by: 12).allSatisfy({
                   self.command(in: bytes, at: $0) != nil
               }) {
                for start in stride(from: offset, to: bytes.count, by: 12) {
                    frames.append(Data(bytes[start..<(start + 12)]))
                }
                break
            }

            // A bad/incomplete length must not hide a later independently complete
            // response. Restrict resynchronization to known command headers, and never
            // search inside an already complete frame's arbitrary binary payload.
            if let next = nextCompleteKnownFrame(in: bytes, after: offset + 11) {
                frames.append(Data(bytes[offset..<next]))
                offset = next
            } else {
                frames.append(Data(bytes[offset..<bytes.count]))
                break
            }
        }
        return frames
    }

    private static func length(in bytes: [UInt8], at offset: Int) -> Int {
        Int(bytes[offset + 10]) | (Int(bytes[offset + 11]) << 8)
    }

    private static func legacyCloseWifiStatus(in bytes: [UInt8], at offset: Int) -> UInt8? {
        guard offset >= 0, bytes.count - offset >= 12,
              bytes[offset..<(offset + 9)].elementsEqual("closewifi".utf8),
              bytes[offset + 9] == 1, bytes[offset + 10] == 0,
              bytes[offset + 11] <= 1 else { return nil }
        return bytes[offset + 11]
    }

    private static func command(in bytes: [UInt8], at offset: Int) -> String? {
        guard offset >= 0, bytes.count - offset >= 10 else { return nil }
        var command: [UInt8] = []
        var reachedPadding = false
        for byte in bytes[offset..<(offset + 10)] {
            if byte == 0 || byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                reachedPadding = true
            } else {
                guard !reachedPadding,
                      (97...122).contains(byte) || (48...57).contains(byte) else { return nil }
                command.append(byte)
            }
        }
        guard let first = command.first, (97...122).contains(first), command.count >= 2 else { return nil }
        return String(bytes: command, encoding: .ascii)
    }

    private static func nextCompleteKnownFrame(in bytes: [UInt8], after offset: Int) -> Int? {
        guard bytes.count >= 12, offset < bytes.count - 12 else { return nil }
        for candidate in (offset + 1)...(bytes.count - 12) {
            if legacyCloseWifiStatus(in: bytes, at: candidate) != nil {
                return candidate
            }
            guard let command = command(in: bytes, at: candidate),
                  knownCommands.contains(command) else { continue }
            let payloadLength = length(in: bytes, at: candidate)
            if payloadLength <= maximumPayloadLength,
               bytes.count - candidate >= 12 + payloadLength {
                return candidate
            }
        }
        return nil
    }
}
