import Foundation

@main
enum Gen1WifiGatewayTests {
    private typealias Policy = Gen1WifiGatewayPolicy
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    private static func path(
        gateways: [String] = ["10.22.8.254"], satisfied: Bool = true,
        wifi: Bool = true, cellular: Bool = false, ipv4: Bool = true,
        interfaces: [String] = ["en0"]
    ) -> Policy.PathSnapshot {
        .init(observedAt: 10, satisfied: satisfied, usesWiFi: wifi, usesCellular: cellular,
              supportsIPv4: ipv4, wifiInterfaces: interfaces, ipv4Gateways: gateways, description: "test")
    }

    private static func select(
        _ snapshot: Policy.PathSnapshot? = path(), ssid: String? = "Glasses AP",
        sampleStarted: TimeInterval? = 11, local: [String] = ["10.22.8.41"]
    ) -> Policy.Decision {
        Policy.selectGateway(targetSSID: "Glasses AP", observedSSID: ssid,
                             ssidSampleStartedAt: sampleStarted, path: snapshot, localIPv4Addresses: local)
    }

    static func main() {
        check(select() == .ready("10.22.8.254"), "Use actual gateway; never change its last octet to .1")
        check(select(path(gateways: ["172.19.11.6"])) == .ready("172.19.11.6"), "Gateway may use any subnet")
        check(select(path(gateways: [])) == .waiting("systemWiFiIPv4GatewayUnavailable"), "Empty gateway must fail, not synthesize a fixed address")
        check(select(path(gateways: ["10.22.8.41"])) == .waiting("systemWiFiIPv4GatewayUnavailable"), "Never use the phone's own IP")
        check(select(path(gateways: ["0.0.0.0", "10.22.8.41", "10.22.8.254"])) == .ready("10.22.8.254"), "Filter invalid and local candidates before selecting gateway")
        check(select(path(gateways: ["10.22.8.254", "10.22.8.1"])) == .ready("10.22.8.254"), "Keep system gateway preference order")
        check(select(ssid: nil) == .waiting("targetSSIDNotConfirmed"), "Missing SSID cannot enable a subnet fallback")
        check(select(ssid: "Home") == .waiting("targetSSIDNotConfirmed"), "Other SSID is never accepted")
        check(select(ssid: "glasses ap") == .waiting("targetSSIDNotConfirmed"), "SSID is case sensitive")
        check(select(ssid: "Glasses AP ") == .waiting("targetSSIDNotConfirmed"), "SSID whitespace is significant")
        check(Policy.matchesSSID(target: " Glasses AP ", observed: " Glasses AP "), "Preserve valid SSID leading and trailing spaces")
        check(!Policy.matchesSSID(target: "Caf\u{00E9}", observed: "Cafe\u{0301}"), "Canonically equivalent Unicode with different UTF-8 bytes is a different SSID")
        check(select(path(gateways: ["192.168.0.1"]), ssid: nil, local: ["192.168.0.2"]) == .waiting("targetSSIDNotConfirmed"), "Gen2 fallback subnet cannot leak into Gen1")
        check(select(nil) == .waiting("wifiPathNotObserved"), "Need an observed Wi-Fi path")
        check(select(sampleStarted: nil) == .waiting("SSIDRevalidationAfterPathRequired"), "Need a completed target SSID sample")
        check(select(sampleStarted: 9) == .waiting("SSIDRevalidationAfterPathRequired"), "Do not combine old SSID with a newer path")
        check(select(path(satisfied: false)) == .waiting("wifiIPv4PathNotReady"), "Wait for satisfied path")
        check(select(path(wifi: false)) == .waiting("wifiIPv4PathNotReady"), "Non-Wi-Fi path is forbidden")
        check(select(path(cellular: true)) == .waiting("wifiIPv4PathNotReady"), "Cellular gateway is forbidden")
        check(select(path(ipv4: false)) == .waiting("wifiIPv4PathNotReady"), "IPv6-only path cannot serve IPv4 transport")
        check(select(path(interfaces: [])) == .waiting("wifiIPv4PathNotReady"), "Need a Wi-Fi interface on this path")
        check(select(local: []) == .waiting("wifiLocalIPv4NotReady"), "DHCP local IPv4 must be ready")
        check(select(local: ["169.254.3.2"]) == .waiting("wifiLocalIPv4NotReady"), "Link-local-only address is not ready")
        for invalid in ["", "0.0.0.0", "0.8.9.1", "127.0.0.1", "169.254.9.1", "224.0.0.1",
                        "239.1.2.3", "240.0.0.1", "255.255.255.255", "256.0.0.1", "1.2.3",
                        "1.2.3.4.5", "01.2.3.4", "1.2.3.", " 10.0.0.1", "10.0.0.1:8556",
                        "::1", "2001:db8::1", "router.local", "1.2.3.-1"] {
            check(!Policy.isUsableIPv4(invalid), "Reject invalid gateway: \(invalid)")
        }
        for valid in ["10.0.0.254", "172.31.16.7", "192.168.8.8", "100.64.0.2"] {
            check(Policy.isUsableIPv4(valid), "Accept usable unicast IPv4: \(valid)")
        }
        print("Gen1 Wi-Fi gateway: \(assertions) assertions passed")
    }
}
