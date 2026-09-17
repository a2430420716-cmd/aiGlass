import Darwin
import Foundation
import NetworkExtension

enum DeviceWifiError: LocalizedError {
    case userDenied
    case joinFailed(String)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .userDenied:
            return L10n.t("已取消加入眼镜 Wi-Fi", "Cancelled joining glasses Wi-Fi")
        case .joinFailed(let detail):
            return L10n.t("连接眼镜 Wi-Fi 失败：\(detail)", "Failed to join glasses Wi-Fi: \(detail)")
        case .unreachable:
            return L10n.t("无法访问眼镜文件服务，请确认已加入热点", "Cannot reach glasses file service. Confirm you joined the hotspot")
        }
    }
}

enum DeviceWifiManager {
    private static let logTag = "[DeviceWifi]"

    /// 加入热点后，等待关联 + 服务可达的最长时间。
    private static let readyTimeout: TimeInterval = 12

    /// 加入眼镜热点：apply 前先清掉旧配置，apply 后轮询到 HTTP 服务真正可达才返回。
    /// 对齐安卓 `DeviceWifiManager.verifyWifiConnection` 的「连上不等于可用」判定。
    /// 失败直接抛出，由相册/录音/OTA 终止本次任务；不在公共层静默重试。
    /// - Parameter probeBaseURL: 眼镜 HTTP 服务地址，用于探测热点是否真正就绪。
    static func connect(
        ssid: String,
        password: String,
        probeBaseURL: String = "http://192.168.0.1/"
    ) async throws {
        let probeEndpoint = ProbeEndpoint(baseURL: probeBaseURL)
        print("\(logTag) join ssid=\(ssid)")
        DebugLogStore.logWiFi(
            "开始加入眼镜热点",
            detail: "targetSSID=\(ssid)\npasswordEmpty=\(password.isEmpty)\nprobe=\(probeEndpoint.host):\(probeEndpoint.port)\nreadyTimeout=\(Int(readyTimeout))s",
            direction: .sent
        )

        // 残留配置会让 apply 直接返回 alreadyAssociated，却未真正关联到眼镜。
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        DebugLogStore.logWiFi("移除旧热点配置", detail: "ssid=\(ssid)")
        try await Task.sleep(nanoseconds: 300_000_000)

        do {
            try await applyConfiguration(ssid: ssid, password: password)
        } catch {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            print("\(logTag) apply failed, abort task: \(error.localizedDescription)")
            let nsError = error as NSError
            DebugLogStore.logWiFi(
                "系统加入热点失败，本次任务终止",
                detail: "ssid=\(ssid)\ndomain=\(nsError.domain)\ncode=\(nsError.code)\nerror=\(error.localizedDescription)",
                direction: .received
            )
            throw error
        }

        guard await waitUntilReady(ssid: ssid, probe: probeEndpoint, timeout: readyTimeout) else {
            print("\(logTag) target hotspot not ready, abort task ssid=\(ssid)")
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            DebugLogStore.logWiFi(
                "热点就绪超时，本次任务终止",
                detail: "targetSSID=\(ssid)\ntimeout=\(Int(readyTimeout))s\nprobe=\(probeEndpoint.host):\(probeEndpoint.port)",
                direction: .received
            )
            throw DeviceWifiError.unreachable
        }

        print("\(logTag) hotspot ready ssid=\(ssid)")
        DebugLogStore.logWiFi(
            "眼镜热点与文件服务已就绪",
            detail: "ssid=\(ssid)\nprobe=\(probeEndpoint.host):\(probeEndpoint.port)",
            direction: .received
        )
    }

    static func disconnect(from ssid: String) {
        print("\(logTag) remove hotspot config ssid=\(ssid)")
        DebugLogStore.logWiFi("断开眼镜热点", detail: "ssid=\(ssid)", direction: .sent)
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        DebugLogStore.logWiFi("热点配置已移除", detail: "ssid=\(ssid)", direction: .received)
    }

    // MARK: - Apply

    private static func applyConfiguration(ssid: String, password: String) async throws {
        DebugLogStore.logWiFi(
            "请求系统加入热点",
            detail: "ssid=\(ssid)\nsecurity=\(password.isEmpty ? "open" : "WPA/WPA2")\njoinOnce=true",
            direction: .sent
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let configuration: NEHotspotConfiguration
            if password.isEmpty {
                configuration = NEHotspotConfiguration(ssid: ssid)
            } else {
                configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
            }
            configuration.joinOnce = true

            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                guard let error = error as NSError? else {
                    print("\(logTag) hotspot apply success")
                    DebugLogStore.logWiFi("系统热点申请成功", detail: "ssid=\(ssid)", direction: .received)
                    continuation.resume()
                    return
                }
                let errorDetail = "ssid=\(ssid)\ndomain=\(error.domain)\ncode=\(error.code)\nerror=\(error.localizedDescription)"
                guard error.domain == NEHotspotConfigurationErrorDomain else {
                    DebugLogStore.logWiFi("系统热点申请返回错误", detail: errorDetail, direction: .received)
                    continuation.resume(throwing: DeviceWifiError.joinFailed(error.localizedDescription))
                    return
                }
                switch error.code {
                case NEHotspotConfigurationError.alreadyAssociated.rawValue:
                    // 「已关联」只说明系统认为配置生效，仍需探测服务可达。
                    print("\(logTag) already associated with \(ssid)")
                    DebugLogStore.logWiFi(
                        "系统报告已关联，继续校验网络",
                        detail: errorDetail,
                        direction: .received
                    )
                    continuation.resume()
                case NEHotspotConfigurationError.userDenied.rawValue:
                    DebugLogStore.logWiFi("用户拒绝加入热点", detail: errorDetail, direction: .received)
                    continuation.resume(throwing: DeviceWifiError.userDenied)
                default:
                    DebugLogStore.logWiFi("系统热点申请失败", detail: errorDetail, direction: .received)
                    continuation.resume(throwing: DeviceWifiError.joinFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Readiness

    private struct ProbeEndpoint {
        let host: String
        let port: UInt16

        init(baseURL: String) {
            let url = URL(string: baseURL)
            host = url?.host ?? "192.168.0.1"
            port = UInt16(url?.port ?? 80)
        }
    }

    /// 轮询直到 Wi-Fi 拿到局域网 IP 且眼镜 HTTP 端口可建连。
    private static func waitUntilReady(
        ssid: String,
        probe: ProbeEndpoint,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var loggedAddress: String?
        var loggedSSID: String?
        var hasLoggedSSID = false
        var lastValidation: String?
        var probeAttempt = 0

        DebugLogStore.logWiFi(
            "等待热点真正可用",
            detail: "targetSSID=\(ssid)\nprobe=\(probe.host):\(probe.port)\ntimeout=\(String(format: "%.1f", timeout))s"
        )

        while Date() < deadline {
            let currentSSID = await currentWiFiSSID()
            if !hasLoggedSSID || currentSSID != loggedSSID {
                hasLoggedSSID = true
                loggedSSID = currentSSID
                print("\(logTag) current ssid=\(currentSSID ?? "nil") target=\(ssid)")
                DebugLogStore.logWiFi(
                    "当前 Wi-Fi 变化",
                    detail: "currentSSID=\(currentSSID ?? "unavailable")\ntargetSSID=\(ssid)",
                    direction: .received
                )
            }

            if let address = currentWiFiIPv4Address() {
                if address != loggedAddress {
                    loggedAddress = address
                    print("\(logTag) wifi ipv4=\(address)")
                    DebugLogStore.logWiFi("Wi-Fi 获取 IPv4", detail: "address=\(address)", direction: .received)
                }
                // 对齐安卓：必须是目标 SSID，或确实拿到眼镜 SoftAP 网段地址。
                // 防止普通路由器/VPN 恰好能访问 192.168.0.1 而被误判为眼镜热点。
                let isTargetNetwork: Bool
                if let currentSSID {
                    // SSID 可读时必须精确匹配；已知连着别的 192.168.0.x 路由器不能降级放行。
                    isTargetNetwork = currentSSID == ssid
                } else {
                    // 系统未授权返回 SSID 时，才按安卓逻辑用眼镜 SoftAP 网段兜底。
                    isTargetNetwork = address.hasPrefix("192.168.0.")
                }
                let validation = "ssid=\(currentSSID ?? "unavailable") address=\(address) matched=\(isTargetNetwork)"
                if validation != lastValidation {
                    lastValidation = validation
                    DebugLogStore.logWiFi(
                        isTargetNetwork ? "热点身份校验通过" : "当前网络不是目标热点",
                        detail: "currentSSID=\(currentSSID ?? "unavailable")\ntargetSSID=\(ssid)\nipv4=\(address)\nmatched=\(isTargetNetwork)",
                        direction: .received
                    )
                }
                guard isTargetNetwork else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                probeAttempt += 1
                DebugLogStore.logWiFi(
                    "探测眼镜文件服务",
                    detail: "attempt=\(probeAttempt)\nhost=\(probe.host)\nport=\(probe.port)\ntimeout=\(String(format: "%.1f", min(3, remaining)))s",
                    direction: .sent
                )
                let reachable = await TCPReachability.canConnect(
                    host: probe.host,
                    port: probe.port,
                    timeout: min(3, remaining)
                )
                DebugLogStore.logWiFi(
                    reachable ? "眼镜文件服务探测成功" : "眼镜文件服务暂不可达",
                    detail: "attempt=\(probeAttempt)\nhost=\(probe.host)\nport=\(probe.port)\nreachable=\(reachable)",
                    direction: .received
                )
                if reachable {
                    return true
                }
            } else {
                let validation = "no-ip"
                if validation != lastValidation {
                    lastValidation = validation
                    DebugLogStore.logWiFi("Wi-Fi 尚未获取 IPv4", detail: "targetSSID=\(ssid)", direction: .received)
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// `fetchCurrent` 对本 App 通过 NEHotspotConfiguration 加入的网络可返回 SSID。
    private static func currentWiFiSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                let value = network?.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: value?.isEmpty == false ? value : nil)
            }
        }
    }

    /// 取当前 Wi-Fi 接口（enX）的 IPv4 地址；未关联时为 nil。
    private static func currentWiFiIPv4Address() -> String? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0 else { return nil }
        defer { freeifaddrs(addressList) }

        var cursor = addressList
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard String(cString: current.pointee.ifa_name).hasPrefix("en") else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let text = String(cString: buffer)
                if !text.isEmpty, !text.hasPrefix("169.254.") { return text }
            }
        }
        return nil
    }
}
