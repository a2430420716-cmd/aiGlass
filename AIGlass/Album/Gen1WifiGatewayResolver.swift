import Foundation
import Network
import NetworkExtension

/// Per-attempt observer; neither SSID reads nor NWPath callbacks suspend a continuation.
/// The polling task remains cancellable even when a system callback never returns.
@MainActor
final class Gen1WifiGatewayResolver {
    private let targetSSID: String
    private let diagnostics: WifiDiagnosticSession
    private let queue = DispatchQueue(label: "com.aiglass.gen1.wifi-gateway")
    private var active = true
    private var monitor: NWPathMonitor?
    private var monitorID: UUID?
    private var path: Gen1WifiGatewayPolicy.PathSnapshot?
    private var pendingSSIDRead: UUID?
    private var observedSSID: String?
    private var ssidSampleStartedAt: TimeInterval?
    private var lastLoggedEvidence: String?
    private var lastDecision = Gen1WifiGatewayPolicy.Decision.waiting("targetSSIDNotConfirmed")

    init(targetSSID: String, diagnostics: WifiDiagnosticSession) {
        self.targetSSID = targetSSID
        self.diagnostics = diagnostics
    }

    func resolve(timeout: TimeInterval = 30) async throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        defer { stop() }
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            startSSIDReadIfNeeded()
            let interfaces = WifiDiagnosticSession.captureInterfaces()
            let wifiNames = Set(path?.wifiInterfaces ?? [])
            let localIPv4 = interfaces.addresses.compactMap { item -> String? in
                guard interfaces.enumerationError == nil, wifiNames.contains(item.name),
                      item.family == "IPv4", item.isUp, !item.isLoopback else { return nil }
                return item.address
            }
            lastDecision = Gen1WifiGatewayPolicy.selectGateway(
                targetSSID: targetSSID, observedSSID: observedSSID,
                ssidSampleStartedAt: ssidSampleStartedAt, path: path,
                localIPv4Addresses: localIPv4
            )
            let evidence = "targetSSID=\(targetSSID.debugDescription) observedSSID=\(observedSSID?.debugDescription ?? "unavailable")"
                + "\nidentityPolicy=exactSSIDRequired subnetFallback=false"
                + "\nstate=\(lastDecision) localWiFiIPv4=\(localIPv4)"
                + "\npath=[\(path?.description ?? "notObserved")]"
                + "\nserviceProtocol=TCP servicePort=8556 TCPVerified=false"
            if evidence != lastLoggedEvidence {
                lastLoggedEvidence = evidence
                diagnostics.log("热点与网关观察", detail: evidence, direction: .received)
            }
            if case .ready(let gateway) = lastDecision {
                try Task.checkCancellation()
                return gateway
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            try await Task.sleep(nanoseconds: UInt64(min(0.5, remaining) * 1_000_000_000))
        }
        try Task.checkCancellation()
        diagnostics.log("热点网关等待超时", detail: "\(lastLoggedEvidence ?? "noEvidence")\ntimeout=\(timeout)s", direction: .received)
        if !Gen1WifiGatewayPolicy.matchesSSID(target: targetSSID, observed: observedSSID) {
            throw DeviceWifiError.joinFailed(L10n.t("未能确认手机已连接到眼镜热点，请检查 Wi-Fi 连接后重试", "Could not confirm that your phone is connected to the glasses hotspot. Check the Wi-Fi connection and try again"))
        }
        throw DeviceWifiError.joinFailed(L10n.t("系统未提供目标眼镜热点的有效 IPv4 网关，请重新开启眼镜热点后重试", "The system did not provide a valid IPv4 gateway for the glasses hotspot. Restart its hotspot and retry"))
    }

    private func startSSIDReadIfNeeded() {
        guard active, pendingSSIDRead == nil else { return }
        let token = UUID()
        let startedAt = ProcessInfo.processInfo.systemUptime
        pendingSSIDRead = token
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            // SSIDs are byte-sensitive identifiers. Do not trim or case-fold them.
            let ssid = network?.ssid
            Task { @MainActor [weak self] in
                guard let self, self.active, self.pendingSSIDRead == token else { return }
                self.pendingSSIDRead = nil
                self.observedSSID = ssid
                self.ssidSampleStartedAt = startedAt
                if Gen1WifiGatewayPolicy.matchesSSID(target: self.targetSSID, observed: ssid) {
                    if self.monitor == nil { self.startMonitor() }
                } else {
                    // Never retain a gateway from a previous network after SSID changes.
                    self.stopMonitor()
                }
            }
        }
    }

    private func startMonitor() {
        let token = UUID()
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        self.monitor = monitor
        monitorID = token
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = Self.snapshot(path)
            Task { @MainActor [weak self] in
                guard let self, self.active, self.monitorID == token else { return }
                self.path = snapshot
            }
        }
        monitor.start(queue: queue)
    }

    private func stopMonitor() {
        monitorID = nil
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
        path = nil
    }

    private func stop() {
        active = false
        pendingSSIDRead = nil
        stopMonitor()
    }

    nonisolated private static func snapshot(_ path: Network.NWPath) -> Gen1WifiGatewayPolicy.PathSnapshot {
        let gateways: [String] = path.gateways.compactMap { endpoint in
            guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host else { return nil }
            return address.rawValue.map(String.init).joined(separator: ".")
        }
        let interfaces = path.availableInterfaces.filter { $0.type == .wifi }.map(\.name)
        let usesWiFi = path.usesInterfaceType(.wifi)
        let usesCellular = path.usesInterfaceType(.cellular)
        let description = "status=\(path.status) usesWiFi=\(usesWiFi) usesCellular=\(usesCellular)"
            + " supportsIPv4=\(path.supportsIPv4) wifiInterfaces=\(interfaces) systemIPv4Gateways=\(gateways)"
        return .init(observedAt: ProcessInfo.processInfo.systemUptime, satisfied: path.status == .satisfied,
                     usesWiFi: usesWiFi, usesCellular: usesCellular, supportsIPv4: path.supportsIPv4,
                     wifiInterfaces: interfaces, ipv4Gateways: gateways, description: description)
    }
}
