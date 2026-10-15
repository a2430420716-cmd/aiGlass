import Foundation

/// Describes observable connection evidence without inferring association or DHCP failures.
nonisolated enum WifiConnectionDiagnostics {
    static func isGen1ClientIPv4(_ address: String?) -> Bool {
        guard let address else { return false }
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "192", parts[1] == "168", parts[2] == "4",
              let host = Int(parts[3]), (2...254).contains(host) else { return false }
        return true
    }

    /// Logs only credential TLVs, preserving bytes before the protocol parser trims
    /// whitespace and NUL padding. This evidence is never used as connection input.
    static func credentialFields(in packet: Data) -> String {
        // Data slices can have nonzero indices; a byte array gives this reader a
        // fixed zero-based view without assuming anything about the caller.
        let bytes = [UInt8](packet)
        guard bytes.count >= 12 else {
            return "credentialFields=unavailable packetStatus=truncatedHeader packetBytes=\(bytes.count) requiredHeaderBytes=12"
        }
        let declaredPayloadBytes = Int(bytes[10]) | (Int(bytes[11]) << 8)
        let declaredEnd = 12 + declaredPayloadBytes
        let payloadEnd = min(bytes.count, declaredEnd)
        let packetStatus = bytes.count < declaredEnd ? "truncated" : "complete"
        var lines = [
            "credentialPacketStatus=\(packetStatus) declaredPayloadBytes=\(declaredPayloadBytes)"
                + " availablePayloadBytes=\(payloadEnd - 12) trailingBytesOutsidePayload=\(max(0, bytes.count - declaredEnd))"
        ]
        var offset = 12
        var fieldCount = 0
        while offset < payloadEnd {
            guard payloadEnd - offset >= 7 else {
                lines.append("credentialFieldsScan=truncatedTLVHeader availableHeaderBytes=\(payloadEnd - offset)")
                break
            }
            let keyBytes = bytes[offset..<(offset + 5)]
            let key = (String(bytes: keyBytes, encoding: .ascii) ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
            let lower = key.lowercased()
            let isCredential = lower.hasPrefix("ssid") || lower.hasPrefix("psw")
                || lower.hasPrefix("pass") || lower.hasPrefix("pwd")
            let declaredBytes = Int(bytes[offset + 5]) | (Int(bytes[offset + 6]) << 8)
            offset += 7
            let availableBytes = min(declaredBytes, payloadEnd - offset)
            let complete = availableBytes == declaredBytes
            if isCredential {
                fieldCount += 1
                lines.append(credentialFieldDescription(
                    key: key,
                    declaredBytes: declaredBytes,
                    value: Array(bytes[offset..<(offset + availableBytes)]),
                    complete: complete
                ))
            }
            guard complete else {
                lines.append("credentialFieldsScan=truncatedTLVValue")
                break
            }
            offset += declaredBytes
        }
        if fieldCount == 0 { lines.append("credentialFields=none") }
        return lines.joined(separator: "\n")
    }

    private static func credentialFieldDescription(
        key: String,
        declaredBytes: Int,
        value: [UInt8],
        complete: Bool
    ) -> String {
        let preview = value.prefix(128)
        let omittedBytes = value.count - preview.count
        let previewText = String(bytes: preview, encoding: .utf8)?.debugDescription
        let utf8: String
        if !complete {
            utf8 = "rawUTF8=<truncated> rawUTF8Preview=\(previewText ?? "<invalidOrIncompleteUTF8>")"
        } else if String(bytes: value, encoding: .utf8) == nil {
            utf8 = "rawUTF8=<invalidUTF8>"
        } else if omittedBytes > 0 {
            utf8 = "rawUTF8=<preview> rawUTF8Preview=\(previewText ?? "<incompleteUTF8SequenceAtPreviewBoundary>")"
        } else {
            utf8 = "rawUTF8=\(previewText ?? "<invalidUTF8>")"
        }
        let hex = preview.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "credentialField=\(key.debugDescription) status=\(complete ? "complete" : "truncated")"
            + " declaredBytes=\(declaredBytes) rawBytes=\(value.count) \(utf8)"
            + " rawHex=\(hex.isEmpty ? "<empty>" : hex) omittedBytes=\(omittedBytes)"
    }

    nonisolated struct InterfaceAddress: Equatable {
        let name: String
        let family: String
        let address: String?
        let isUp: Bool
        let isRunning: Bool
        let isLoopback: Bool
        let flags: UInt32
        let addressError: Int32?

        fileprivate var rejectionReasons: [String] {
            var reasons: [String] = []
            if !name.hasPrefix("en") { reasons.append("notWiFiInterface") }
            if !isUp { reasons.append("interfaceDown") }
            if isLoopback { reasons.append("loopback") }
            if family != "IPv4" { reasons.append("notIPv4") }
            if address?.isEmpty != false { reasons.append("addressUnavailable") }
            if family == "IPv4", address?.hasPrefix("169.254.") == true {
                reasons.append("linkLocalIPv4")
            }
            return reasons
        }
    }

    nonisolated struct Interfaces: Equatable {
        let addresses: [InterfaceAddress]
        let enumerationError: Int32?

        /// Keep the existing en*, UP, non-loopback IPv4 selection and list order.
        /// RUNNING remains diagnostic evidence, not a new connection requirement.
        var selectedIPv4: String? {
            guard enumerationError == nil else { return nil }
            return addresses.first { $0.rejectionReasons.isEmpty }?.address
        }
    }

    static func interfaceDescription(_ interfaces: Interfaces) -> String {
        var lines = ["enumerationError=\(interfaces.enumerationError.map(String.init) ?? "none")"]
        if interfaces.addresses.isEmpty { lines.append("interfaces=none") }
        lines += interfaces.addresses.map { item in
            let reasons = item.rejectionReasons
            let eligibility = reasons.isEmpty ? "eligibleIPv4" : "rejected(\(reasons.joined(separator: ",")))"
            return "interface=\(item.name) flags=0x\(String(item.flags, radix: 16))"
                + " up=\(item.isUp) running=\(item.isRunning) loopback=\(item.isLoopback)"
                + " family=\(item.family) address=\(item.address ?? "unavailable")"
                + " addressError=\(item.addressError.map(String.init) ?? "none")"
                + " eligibility=\(eligibility)"
        }
        return lines.joined(separator: "\n")
    }

    static func matchesTargetNetwork(address: String, currentSSID: String?, targetSSID: String) -> Bool {
        if let currentSSID {
            // An observed other SSID cannot be overridden by an overlapping subnet.
            return currentSSID == targetSSID
        }
        // An unavailable SSID does not prove disconnection. Preserve the SoftAP fallback.
        return address.hasPrefix("192.168.0.")
    }

    /// readyForTCP means only that the existing preconditions allow a TCP probe.
    /// It does not establish TCP reachability or identify an IP provisioning cause.
    static func readinessStage(interfaces: Interfaces, currentSSID: String?, targetSSID: String) -> String {
        guard interfaces.enumerationError == nil else { return "interfaceEnumerationFailed" }
        let wifi = interfaces.addresses.filter { $0.name.hasPrefix("en") && !$0.isLoopback }
        guard !wifi.isEmpty else { return "noWiFiInterface" }
        let up = wifi.filter(\.isUp)
        guard !up.isEmpty else { return "wifiInterfaceDown" }
        guard let address = interfaces.selectedIPv4 else {
            if up.contains(where: { $0.family == "IPv4" && $0.address?.hasPrefix("169.254.") == true }) {
                return "linkLocalIPv4Only"
            }
            return "noUsableWiFiIPv4"
        }
        return matchesTargetNetwork(address: address, currentSSID: currentSSID, targetSSID: targetSSID)
            ? "readyForTCP" : "differentNetwork"
    }

    nonisolated struct SnapshotLogGate {
        private var lastSignature: String?
        private var lastLoggedAt: TimeInterval?

        /// Emit changes immediately, repeat unchanged evidence every three seconds,
        /// and always retain explicitly forced terminal snapshots.
        mutating func shouldLog(signature: String, now: TimeInterval, force: Bool = false) -> Bool {
            let elapsed = lastLoggedAt.map { now - $0 } ?? .infinity
            guard force || signature != lastSignature || elapsed >= 3 || elapsed < 0 else {
                return false
            }
            lastSignature = signature
            lastLoggedAt = now
            return true
        }
    }
}
