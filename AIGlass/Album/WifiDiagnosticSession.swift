import Darwin
import Foundation
import Network
import NetworkExtension
import UIKit

/// Observes one hotspot attempt. Monitoring never selects a network or decides readiness.
@MainActor
final class WifiDiagnosticSession {
    let id: String
    let targetSSID: String
    private let deviceEvidence: (@MainActor () -> String)?
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let defaultMonitor = NWPathMonitor()
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let monitorQueue = DispatchQueue(label: "com.aiglass.wifi.diagnostics")
    private var observers: [NSObjectProtocol] = []
    private var stopped = false
    private var defaultPath = "notObserved"
    private var wifiPath = "notObserved"
    private var snapshotGate = WifiConnectionDiagnostics.SnapshotLogGate()
    private var pendingSSIDRead: UUID?
    private var ssidReadCount = 0
    private var ssidReadDuration: TimeInterval?
    private var ssidObservedAt: TimeInterval?
    private var ssidReadState = "notRequested"
    private var recordedProbeAttempts = 0
    private var recordedProbeResult: Bool?
    private(set) var currentSSID: String?

    init(targetSSID: String, context: String, id: String, deviceEvidence: (@MainActor () -> String)? = nil) {
        self.id = id
        self.targetSSID = targetSSID
        self.deviceEvidence = deviceEvidence
        observe(defaultMonitor, label: "default")
        observe(wifiMonitor, label: "wifiRequired")
        let names: [Notification.Name] = [
            UIApplication.willResignActiveNotification,
            UIApplication.didBecomeActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let event = notification.name.rawValue
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    self.log("热点等待期间 App 状态变化", detail: "event=\(event)\n\(self.applicationDescription)")
                    self.recordSnapshot(phase: "lifecycle-change", force: true)
                }
            })
        }
        log("热点连接诊断开始", detail: "diagnosticVersion=2 context=\(context.debugDescription)\ntargetSSID=\(targetSSID.debugDescription)\njoinOnce=true\nssidEntitlement=notVerifiedAtRuntime requiresWifiInfoEntitlement=true\nevidenceLimit=SSID_nil_does_not_prove_disconnection; NWPath_is_not_target_association_or_DHCP_evidence")
    }

    func stop() {
        stopped = true
        pendingSSIDRead = nil
        defaultMonitor.pathUpdateHandler = nil
        wifiMonitor.pathUpdateHandler = nil
        defaultMonitor.cancel()
        wifiMonitor.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func log(_ title: String, detail: String = "", direction: DebugLogStore.Direction = .event) {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        DebugLogStore.logWiFi(
            title,
            detail: "diagnosticID=\(id) uptime=\(String(format: "%.3f", now)) elapsed=\(String(format: "%.3f", now - startedAt))s\n\(detail)",
            direction: direction
        )
    }

    /// Preserve the API's nil result without assigning an unobservable cause to it.
    func fetchCurrentSSID() async -> String? {
        let token = UUID()
        pendingSSIDRead = token
        ssidReadCount += 1
        let attempt = ssidReadCount
        let started = ProcessInfo.processInfo.systemUptime
        if attempt == 1 { log("开始读取当前 SSID", detail: "ssidReadAttempt=\(attempt)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.stopped, self.pendingSSIDRead == token else { return }
            self.log("SSID 读取回调尚未返回", detail: "ssidReadAttempt=\(attempt) waited=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s\n\(self.applicationDescription)")
            self.recordSnapshot(phase: "ssid-callback-pending", force: true)
        }
        let ssid: String? = await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                let value = network?.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: value?.isEmpty == false ? value : nil)
            }
        }
        pendingSSIDRead = nil
        let previous = ssidReadState
        currentSSID = ssid
        ssidObservedAt = ProcessInfo.processInfo.systemUptime
        ssidReadDuration = ProcessInfo.processInfo.systemUptime - started
        ssidReadState = ssid == nil ? "unavailableReasonNotExposed" : "available"
        if attempt == 1 || previous != ssidReadState || (ssidReadDuration ?? 0) >= 1 {
            log("当前 SSID 读取完成", detail: ssidDescription, direction: .received)
        }
        return ssid
    }

    @discardableResult
    func recordSnapshot(
        phase: String,
        interfaces: WifiConnectionDiagnostics.Interfaces? = nil,
        probeAttempts: Int? = nil,
        lastProbeSucceeded: Bool? = nil,
        force: Bool = false
    ) -> String {
        if let probeAttempts { recordedProbeAttempts = probeAttempts }
        if let lastProbeSucceeded { recordedProbeResult = lastProbeSucceeded }
        let interfaces = interfaces ?? Self.captureInterfaces()
        let stage = WifiConnectionDiagnostics.readinessStage(interfaces: interfaces, currentSSID: currentSSID, targetSSID: targetSSID)
        let interfaceDetail = WifiConnectionDiagnostics.interfaceDescription(interfaces)
        let evidence = "phase=\(phase) observedStage=\(stage)\nlastObservedSSID=\(currentSSID?.debugDescription ?? "unavailable") ssidReadState=\(ssidReadState)\nselectedIPv4=\(interfaces.selectedIPv4 ?? "none")\n\(interfaceDetail)\ndefaultPath=[\(defaultPath)]\nwifiRequiredPath=[\(wifiPath)]\n\(applicationDescription)\n\(deviceEvidence?() ?? "deviceEvidence=notProvided")\nprobeAttempts=\(recordedProbeAttempts) lastProbeSucceeded=\(recordedProbeResult.map(String.init) ?? "notAttempted")"
        if snapshotGate.shouldLog(signature: evidence, now: ProcessInfo.processInfo.systemUptime, force: force) {
            log("热点连接现场快照", detail: "\(evidence)\n\(ssidDescription)\nevidenceLimit=interface_names_are_candidates; link_local_IPv4_does_not_prove_DHCP_failure; path_ready_does_not_prove_target_or_HTTP_ready")
        }
        return stage
    }

    private var ssidDescription: String {
        let age = ssidObservedAt.map { String(format: "%.3f", ProcessInfo.processInfo.systemUptime - $0) } ?? "none"
        return "ssidReadAttempt=\(ssidReadCount) readPending=\(pendingSSIDRead != nil) result=\(ssidReadState) lastObservedSSID=\(currentSSID?.debugDescription ?? "unavailable") age=\(age)s duration=\(ssidReadDuration.map { String(format: "%.3f", $0) } ?? "none")s\nssidEligibility=notVerified; requires_wifi_info_entitlement_and_API_criteria; nil_reason_not_exposed"
    }

    private var applicationDescription: String {
        let app = UIApplication.shared
        let state: String
        switch app.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        return "appState=\(state) protectedDataAvailable=\(app.isProtectedDataAvailable)"
    }

    private func observe(_ monitor: NWPathMonitor, label: String) {
        monitor.pathUpdateHandler = { [weak self] path in
            let detail = Self.describe(path)
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                if label == "default" { self.defaultPath = detail }
                else { self.wifiPath = detail }
                self.log("热点等待期间网络路径变化", detail: "monitor=\(label) \(detail)")
            }
        }
        monitor.start(queue: monitorQueue)
    }

    nonisolated private static func describe(_ path: Network.NWPath) -> String {
        let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.sorted().joined(separator: ",")
        let reason = path.status == .unsatisfied ? String(describing: path.unsatisfiedReason) : "notApplicable"
        return "status=\(path.status) unsatisfiedReason=\(reason) usesWiFi=\(path.usesInterfaceType(.wifi)) usesCellular=\(path.usesInterfaceType(.cellular)) supportsIPv4=\(path.supportsIPv4) supportsIPv6=\(path.supportsIPv6) supportsDNS=\(path.supportsDNS) expensive=\(path.isExpensive) constrained=\(path.isConstrained) interfaces=[\(interfaces)]"
    }

    nonisolated static func captureInterfaces() -> WifiConnectionDiagnostics.Interfaces {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else {
            return .init(addresses: [], enumerationError: errno)
        }
        defer { freeifaddrs(list) }
        var result: [WifiConnectionDiagnostics.InterfaceAddress] = []
        var cursor = list
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = item.pointee.ifa_flags
            let address = item.pointee.ifa_addr
            let family = address.map { Int32($0.pointee.sa_family) }
            var numeric: String?
            var addressError: Int32?
            if let address, family == AF_INET || family == AF_INET6 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                if status == 0 { numeric = String(cString: buffer) }
                else { addressError = status }
            }
            let familyName: String
            switch family {
            case AF_INET: familyName = "IPv4"
            case AF_INET6: familyName = "IPv6"
            case AF_LINK: familyName = "link"
            default: familyName = "other"
            }
            result.append(.init(
                name: String(cString: item.pointee.ifa_name), family: familyName, address: numeric,
                isUp: (flags & UInt32(IFF_UP)) != 0, isRunning: (flags & UInt32(IFF_RUNNING)) != 0,
                isLoopback: (flags & UInt32(IFF_LOOPBACK)) != 0, flags: flags, addressError: addressError
            ))
        }
        return .init(addresses: result, enumerationError: nil)
    }
}
