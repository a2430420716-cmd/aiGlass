import Foundation

/// First-generation transport must use a gateway reported by the Wi-Fi path.
/// Local interface addresses are exclusion evidence, never gateway candidates.
nonisolated enum Gen1WifiGatewayPolicy {
    struct PathSnapshot: Equatable, Sendable {
        let observedAt: TimeInterval
        let satisfied: Bool
        let usesWiFi: Bool
        let usesCellular: Bool
        let supportsIPv4: Bool
        let wifiInterfaces: [String]
        let ipv4Gateways: [String]
        let description: String
    }

    enum Decision: Equatable, Sendable {
        case waiting(String)
        case ready(String)
    }

    static func selectGateway(
        targetSSID: String,
        observedSSID: String?,
        ssidSampleStartedAt: TimeInterval?,
        path: PathSnapshot?,
        localIPv4Addresses: [String]
    ) -> Decision {
        guard matchesSSID(target: targetSSID, observed: observedSSID) else {
            return .waiting("targetSSIDNotConfirmed")
        }
        guard let path else { return .waiting("wifiPathNotObserved") }
        guard let ssidSampleStartedAt, ssidSampleStartedAt >= path.observedAt else {
            return .waiting("SSIDRevalidationAfterPathRequired")
        }
        guard path.satisfied, path.usesWiFi, !path.usesCellular,
              path.supportsIPv4, !path.wifiInterfaces.isEmpty else {
            return .waiting("wifiIPv4PathNotReady")
        }
        let local = Set(localIPv4Addresses.filter(isUsableIPv4))
        guard !local.isEmpty else { return .waiting("wifiLocalIPv4NotReady") }
        guard let gateway = path.ipv4Gateways.first(where: { isUsableIPv4($0) && !local.contains($0) }) else {
            return .waiting("systemWiFiIPv4GatewayUnavailable")
        }
        return .ready(gateway)
    }

    static func matchesSSID(target: String, observed: String?) -> Bool {
        guard !target.isEmpty, let observed else { return false }
        // Swift String equality normalizes Unicode; SSID identity must preserve UTF-8 bytes.
        return target.utf8.elementsEqual(observed.utf8)
    }

    static func isUsableIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  !(part.count > 1 && part.first == "0"), let value = UInt8(part) else { return false }
            octets.append(value)
        }
        // No unspecified, loopback, link-local, multicast, or reserved/broadcast address.
        guard octets[0] != 0, octets[0] != 127, octets[0] < 224,
              !(octets[0] == 169 && octets[1] == 254) else { return false }
        return true
    }
}
