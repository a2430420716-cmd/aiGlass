import Foundation

@main
@MainActor
enum WifiConnectionDiagnosticsTests {
    private typealias Diagnostics = WifiConnectionDiagnostics
    private typealias Address = Diagnostics.InterfaceAddress
    private typealias Interfaces = Diagnostics.Interfaces
    private static let targetSSID = "AIGlass_Test"
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    static func main() {
        missingSSIDDoesNotProveDisconnection()
        knownOtherNetworkCannotUseSubnetFallback()
        interfaceEvidencePreservesFailureBoundaries()
        ipv4SelectionPreservesExistingBehavior()
        interfaceDescriptionsRetainRejectedEvidence()
        snapshotsAreLimitedWithoutLosingTransitions()
        credentialLogsPreserveUntrimmedValues()
        credentialLogsRespectEveryDeclaredBoundary()
        credentialLogsBoundPreviewsAndRejectInvalidUTF8()
        check(nonisolatedUseCompiles(), "Diagnostic values must be usable outside MainActor")
        print("Wi-Fi connection diagnostics: \(assertions) assertions passed")
    }

    private static func address(
        _ value: String? = "192.168.0.2",
        name: String = "en0",
        family: String = "IPv4",
        up: Bool = true,
        running: Bool = true,
        loopback: Bool = false,
        flags: UInt32 = 0x8863,
        error: Int32? = nil
    ) -> Address {
        Address(name: name, family: family, address: value, isUp: up, isRunning: running,
                isLoopback: loopback, flags: flags, addressError: error)
    }

    private static func stage(_ addresses: [Address], ssid: String? = nil, error: Int32? = nil) -> String {
        Diagnostics.readinessStage(
            interfaces: Interfaces(addresses: addresses, enumerationError: error),
            currentSSID: ssid,
            targetSSID: targetSSID
        )
    }

    private static func missingSSIDDoesNotProveDisconnection() {
        check(stage([address(nil, family: "link")]) == "noUsableWiFiIPv4",
              "The reported unavailable SSID and missing IPv4 must stop before TCP, without inferring DHCP failure")
        check(stage([address()]) == "readyForTCP",
              "An unavailable SSID with a SoftAP IPv4 retains the existing TCP probe fallback")
        check(stage([address("10.0.0.2")]) == "differentNetwork",
              "An unavailable SSID does not permit an arbitrary Wi-Fi subnet")
        check(stage([address("10.0.0.2")], ssid: targetSSID) == "readyForTCP",
              "An observed target SSID retains existing acceptance outside the fallback subnet")
        check(stage([address(nil, family: "link")], ssid: targetSSID) == "noUsableWiFiIPv4",
              "A matching SSID still requires a usable IPv4 before TCP")
    }

    private static func knownOtherNetworkCannotUseSubnetFallback() {
        check(!Diagnostics.matchesTargetNetwork(address: "192.168.0.2", currentSSID: "Home", targetSSID: targetSSID),
              "A home router with the same subnet cannot impersonate the target SSID")
        check(stage([address()], ssid: "Home") == "differentNetwork",
              "A known other SSID must be identified despite an overlapping subnet")
        check(Diagnostics.matchesTargetNetwork(address: "192.168.0.2", currentSSID: nil, targetSSID: targetSSID),
              "Only absent SSID enables the SoftAP subnet fallback")
        check(!Diagnostics.matchesTargetNetwork(address: "192.168.01.2", currentSSID: nil, targetSSID: targetSSID),
              "The fallback requires the original subnet prefix including its final dot")
        check(!Diagnostics.matchesTargetNetwork(address: "192.168.0.2", currentSSID: "aiglass_test", targetSSID: targetSSID),
              "SSID matching remains case sensitive")
    }

    private static func interfaceEvidencePreservesFailureBoundaries() {
        check(stage([], error: 13) == "interfaceEnumerationFailed",
              "An interface enumeration error is not evidence that Wi-Fi is absent")
        check(stage([address()], error: 13) == "interfaceEnumerationFailed",
              "Enumeration failure takes precedence over any incomplete address list")
        check(Interfaces(addresses: [address()], enumerationError: 13).selectedIPv4 == nil,
              "An enumeration failure cannot feed partial evidence into connection readiness")
        check(stage([]) == "noWiFiInterface", "A successful empty enumeration reports no Wi-Fi interface")
        check(stage([address(name: "pdp_ip0")]) == "noWiFiInterface",
              "A cellular IPv4 cannot masquerade as a Wi-Fi address")
        check(stage([address(name: "utun1")]) == "noWiFiInterface",
              "A VPN IPv4 cannot masquerade as a Wi-Fi address")
        check(stage([address(name: "lo0", loopback: true)]) == "noWiFiInterface",
              "Loopback addresses are not Wi-Fi evidence")
        check(stage([address(up: false)]) == "wifiInterfaceDown",
              "A down interface must be distinguished from absent IPv4 on an up interface")
        check(stage([address("169.254.25.8")]) == "linkLocalIPv4Only",
              "A link-local address must survive as diagnostic evidence")
        check(stage([address("fe80::1%en0", family: "IPv6")]) == "noUsableWiFiIPv4",
              "IPv6-only Wi-Fi is observable but does not satisfy the existing IPv4 prerequisite")
        check(stage([address(nil, error: 8)]) == "noUsableWiFiIPv4",
              "An address formatting failure must not create a usable IPv4")
        check(stage([address("169.254.25.8", up: false), address("fe80::1", family: "IPv6")]) == "noUsableWiFiIPv4",
              "A down interface's stale link-local address must not describe the active interface")
        check(stage([address("169.254.25.8"), address()]) == "readyForTCP",
              "A link-local address cannot hide a later usable IPv4")
    }

    private static func ipv4SelectionPreservesExistingBehavior() {
        let candidates = [
            address(name: "pdp_ip0"),
            address(up: false),
            address(loopback: true),
            address("fe80::1", family: "IPv6"),
            address(nil),
            address(""),
            address("169.254.1.2"),
            address("10.0.0.8", name: "en1", running: false),
            address()
        ]
        check(Interfaces(addresses: candidates, enumerationError: nil).selectedIPv4 == "10.0.0.8",
              "Select the first valid en* IPv4 in enumeration order; do not add a RUNNING requirement")
        check(stage(candidates) == "differentNetwork",
              "Do not silently skip the first valid address to select a later SoftAP subnet")
        check(Interfaces(addresses: [address(loopback: true)], enumerationError: nil).selectedIPv4 == nil,
              "Even an en* interface cannot be accepted when its loopback flag is set")
        check(stage([address(running: false)]) == "readyForTCP",
              "RUNNING evidence must not tighten existing connection behavior")
    }

    private static func interfaceDescriptionsRetainRejectedEvidence() {
        let description = Diagnostics.interfaceDescription(Interfaces(addresses: [
            address("169.254.25.8"),
            address("fe80::abcd%en0", family: "IPv6"),
            address(nil, family: "link"),
            address("192.168.0.9", name: "pdp_ip0"),
            address(nil, up: false, running: false, flags: 0x8000, error: 8)
        ], enumerationError: nil))
        for evidence in ["169.254.25.8", "linkLocalIPv4", "fe80::abcd%en0", "family=IPv6", "family=link",
                         "notIPv4", "interface=pdp_ip0", "notWiFiInterface", "flags=0x8000", "running=false",
                         "interfaceDown", "addressUnavailable", "addressError=8"] {
            check(description.contains(evidence), "The log must preserve evidence: \(evidence)")
        }
        check(Diagnostics.interfaceDescription(Interfaces(addresses: [], enumerationError: 13))
            .contains("enumerationError=13"), "The raw enumeration error must remain inspectable")
        check(Diagnostics.interfaceDescription(Interfaces(addresses: [address()], enumerationError: nil))
            .contains("eligibility=eligibleIPv4"), "A usable address must be explicitly distinguished from rejected entries")
    }

    private static func snapshotsAreLimitedWithoutLosingTransitions() {
        var gate = Diagnostics.SnapshotLogGate()
        check(gate.shouldLog(signature: "noIPv4", now: 0), "Log the first snapshot")
        for time in [0.5, 1, 1.5, 2, 2.5] {
            check(!gate.shouldLog(signature: "noIPv4", now: time), "Suppress unchanged half-second polling")
        }
        check(gate.shouldLog(signature: "noIPv4", now: 3), "Retain evidence every three seconds")
        check(!gate.shouldLog(signature: "noIPv4", now: 3.5), "Restart the rate limit after a periodic log")
        check(gate.shouldLog(signature: "linkLocal", now: 3.6), "Log changed evidence immediately")
        check(gate.shouldLog(signature: "readyForTCP", now: 3.7), "Do not suppress rapid readiness transitions")
        check(gate.shouldLog(signature: "readyForTCP", now: 3.7, force: true),
              "Always retain a forced terminal snapshot even at the same timestamp")
        check(gate.shouldLog(signature: "readyForTCP", now: 3.8, force: true),
              "Each explicit terminal snapshot bypasses throttling")
        check(!gate.shouldLog(signature: "readyForTCP", now: 6.7), "Forced emission resets the repeat interval")
        check(gate.shouldLog(signature: "readyForTCP", now: 6.8), "Periodic output resumes after the forced emission")
        check(gate.shouldLog(signature: "readyForTCP", now: 1), "A clock reset must not suppress evidence indefinitely")
    }

    private static func tlv(_ key: String, _ value: [UInt8], declaredBytes: Int? = nil) -> [UInt8] {
        precondition(key.utf8.count == 5)
        let length = declaredBytes ?? value.count
        return Array(key.utf8) + [UInt8(length & 0xff), UInt8(length >> 8)] + value
    }

    private static func packet(_ payload: [UInt8], declaredPayload: Int? = nil) -> Data {
        let length = declaredPayload ?? payload.count
        return Data(Array("wificonfig".utf8) + [UInt8(length & 0xff), UInt8(length >> 8)] + payload)
    }

    private static func credentialLogsPreserveUntrimmedValues() {
        let ssid = " AIGlass_Test\0 "
        let password = " 1234567\0"
        let log = Diagnostics.credentialFields(in: packet(
            tlv("ssid0", Array(ssid.utf8)) + tlv("psw00", Array(password.utf8))
                + tlv("http0", Array("do-not-log-this-url".utf8))
        ))
        check(log.contains("credentialField=\"ssid0\""), "Record the device's SSID TLV")
        check(log.contains("credentialField=\"psw00\" status=complete declaredBytes=9 rawBytes=9"),
              "The observed psw00 field keeps its original nine-byte length")
        check(log.contains("rawUTF8=\(ssid.debugDescription)"), "SSID whitespace and NUL must stay visible before trimming")
        check(log.contains("rawUTF8=\(password.debugDescription)"), "Password whitespace and NUL must stay visible before trimming")
        check(log.contains("rawHex=20 31 32 33 34 35 36 37 00 omittedBytes=0"),
              "Password bytes must distinguish space and NUL from the normalized password")
        check(!log.contains("http0") && !log.contains("do-not-log-this-url"), "Other TLV names and values must not be logged")
        let aliases = Diagnostics.credentialFields(in: packet(tlv("pass0", []) + tlv("pwd00", [0x41])))
        check(aliases.contains("credentialField=\"pass0\" status=complete declaredBytes=0 rawBytes=0 rawUTF8=\"\" rawHex=<empty>"),
              "An explicitly empty credential remains distinguishable from an incomplete one")
        check(aliases.contains("credentialField=\"pwd00\""), "Support each password key recognized by the existing parser")
        let prefixed = Data([0xff, 0xff]) + packet(tlv("psw00", [0x41]))
        check(Diagnostics.credentialFields(in: prefixed.dropFirst(2)).contains("rawUTF8=\"A\""),
              "Data slices with nonzero start indices must remain safe")
    }

    private static func credentialLogsRespectEveryDeclaredBoundary() {
        let completeTLV = tlv("psw00", Array("123456789".utf8))
        let declaredShort = Diagnostics.credentialFields(in: packet(completeTLV, declaredPayload: 9))
        check(declaredShort.contains("status=truncated declaredBytes=9 rawBytes=2 rawUTF8=<truncated>"),
              "A TLV cannot consume bytes beyond the packet's declared payload")
        check(declaredShort.contains("rawUTF8Preview=\"12\" rawHex=31 32 omittedBytes=0"),
              "An incomplete credential must be explicitly labeled as partial evidence")
        check(!declaredShort.contains("123456789") && !declaredShort.contains("31 32 33"),
              "Bytes physically present beyond the declared payload must never leak into a credential")
        check(declaredShort.contains("trailingBytesOutsidePayload=7"), "Describe trailing bytes without logging their contents")
        let receivedShort = Diagnostics.credentialFields(in: packet(tlv("psw00", [0x41, 0x42], declaredBytes: 9), declaredPayload: 16))
        check(receivedShort.contains("credentialPacketStatus=truncated"), "Identify an incomplete packet separately from its TLV")
        check(receivedShort.contains("status=truncated declaredBytes=9 rawBytes=2"), "A missing field suffix must not become a complete password")
        let lengthOverflow = Diagnostics.credentialFields(in: packet(tlv("ssid0", [0x41], declaredBytes: 65535)))
        check(lengthOverflow.contains("status=truncated declaredBytes=65535 rawBytes=1"), "A maximum length must be handled without reading beyond available bytes")
        let truncatedHeader = Diagnostics.credentialFields(in: packet(Array(completeTLV.prefix(6))))
        check(truncatedHeader.contains("credentialFieldsScan=truncatedTLVHeader"), "An incomplete length field cannot be read")
        check(!truncatedHeader.contains("rawUTF8="), "An incomplete TLV header cannot report a credential value")
        check(Diagnostics.credentialFields(in: Data([0, 1, 2])).contains("packetStatus=truncatedHeader"),
              "A packet shorter than its fixed header must be rejected safely")
        let trailingTLV = Diagnostics.credentialFields(in: packet(tlv("ssid0", [0x41]) + tlv("psw00", Array("outside".utf8)), declaredPayload: 8))
        check(!trailingTLV.contains("psw00") && !trailingTLV.contains("outside"), "A complete extra TLV beyond declared payload must be ignored")
        let unknownMalformed = Diagnostics.credentialFields(in: packet(tlv("http0", Array("private-url".utf8), declaredBytes: 100)))
        check(unknownMalformed.contains("credentialFieldsScan=truncatedTLVValue") && !unknownMalformed.contains("private-url"),
              "Malformed unrelated TLVs must stop scanning without recording their contents")
    }

    private static func credentialLogsBoundPreviewsAndRejectInvalidUTF8() {
        let invalid = Diagnostics.credentialFields(in: packet(tlv("psw00", [0xff, 0xfe])))
        check(invalid.contains("rawUTF8=<invalidUTF8>"), "Invalid UTF-8 must not silently become an empty or repaired password")
        check(invalid.contains("rawHex=FF FE omittedBytes=0"), "The raw bytes must remain usable when UTF-8 decoding fails")
        let longValue = [UInt8](repeating: 0x41, count: 128) + Array("secret-suffix".utf8)
        let long = Diagnostics.credentialFields(in: packet(tlv("psw00", longValue)))
        check(long.contains("status=complete declaredBytes=141 rawBytes=141 rawUTF8=<preview>"),
              "Preview truncation must not be confused with a truncated incoming field")
        check(long.contains("omittedBytes=13"), "Report the exact number of bytes excluded from each preview")
        check(!long.contains("secret-suffix"), "UTF-8 previews must be bounded alongside hex previews")
        let hex = long.components(separatedBy: "rawHex=")[1].components(separatedBy: " omittedBytes=")[0]
        check(hex.split(separator: " ").count == 128, "The hex preview cannot exceed 128 bytes")
        let splitScalar = [UInt8](repeating: 0x41, count: 127) + Array("眼".utf8)
        let split = Diagnostics.credentialFields(in: packet(tlv("psw00", splitScalar)))
        check(split.contains("rawUTF8Preview=<incompleteUTF8SequenceAtPreviewBoundary>"),
              "A preview cutting a valid Unicode scalar must not label the complete field invalid UTF-8")
    }

    nonisolated private static func nonisolatedUseCompiles() -> Bool {
        let interfaces = WifiConnectionDiagnostics.Interfaces(addresses: [], enumerationError: nil)
        var gate = WifiConnectionDiagnostics.SnapshotLogGate()
        return interfaces.selectedIPv4 == nil
            && WifiConnectionDiagnostics.readinessStage(interfaces: interfaces, currentSSID: nil, targetSSID: "Test") == "noWiFiInterface"
            && WifiConnectionDiagnostics.credentialFields(in: Data()).contains("truncatedHeader")
            && gate.shouldLog(signature: WifiConnectionDiagnostics.interfaceDescription(interfaces), now: 0)
    }
}
