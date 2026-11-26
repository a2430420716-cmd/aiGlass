import Foundation

struct Gen1HotspotCredentials: Equatable, Sendable {
    let ssid: String
    let password: String
}

enum Gen1APImportError: LocalizedError, Equatable {
    case invalidCredentials
    case hotspotRejected(UInt8)
    case hotspotTimeout
    case deviceBusy
    case statusUnconfirmed
    case hotspotCleanupPending
    case targetChanged
    case unavailable
    case sendFailed
    case invalidFileName

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "眼镜返回的热点名称或密码无效，请重新开启热点后重试"
        case .hotspotRejected(let code):
            let reason: String
            switch code {
            case 1: reason = "眼镜热点启动失败"
            case 2: reason = "热点服务启动超时"
            case 3: reason = "眼镜热点的网络地址分配服务启动超时"
            case 0xE3: reason = "眼镜正忙，未开启本次导入热点，请稍后重试"
            default: reason = "未知启动失败"
            }
            return "\(reason)（0x\(String(format: "%02X", code))）"
        case .hotspotTimeout: return "等待眼镜热点信息超时，请检查眼镜连接后重试"
        case .deviceBusy: return "设备正在处理，请稍等，待设备空闲后再次导入"
        case .statusUnconfirmed: return "暂未确认设备状态，请稍等后再次导入"
        case .hotspotCleanupPending: return "上次眼镜热点仍在收尾，暂不能再次导入或升级，请稍候重试；若持续无法恢复，请重启眼镜和 App"
        case .targetChanged: return "绑定或连接的眼镜已改变，本次导入已停止"
        case .unavailable: return "眼镜当前不可导入，请先结束录音、拍摄或升级"
        case .sendFailed: return "开启眼镜热点指令未发送，请重新连接后重试"
        case .invalidFileName: return "眼镜返回的文件名无效"
        }
    }
}

/// The main controller can briefly report standby before its final shutdown.
/// Require continuous standby before opening an import hotspot.
struct Gen1APImportStandbyGate {
    static let settleInterval: TimeInterval = 0.75
    private var standbySince: TimeInterval?

    mutating func observe(_ status: Gen1DomainDeviceStatus, at now: TimeInterval) {
        if status == .standby {
            if standbySince == nil { standbySince = now }
        } else {
            standbySince = nil
        }
    }

    func isReady(at now: TimeInterval) -> Bool {
        guard let standbySince else { return false }
        return now - standbySince >= Self.settleInterval
    }
}

enum Gen1APImportProtocol {
    /// Firmware may answer status queries using 0x73, or only notify on changes.
    /// A fresh busy/unknown report always overrides a previously recorded idle.
    static func requireStandby(fresh: Gen1DomainDeviceStatus?, current: Gen1DomainDeviceStatus,
                               lastReported: Gen1DomainDeviceStatus) throws {
        let status = fresh ?? current
        guard status != .unknown else { throw Gen1APImportError.statusUnconfirmed }
        guard status == .standby else { throw Gen1APImportError.deviceBusy }
        if fresh == nil, lastReported != .standby { throw Gen1APImportError.statusUnconfirmed }
    }

    static func isRecordingRequest(command: UInt8, payload: Data) -> Bool {
        command == Gen1Commands.aiRecord && payload.count == 1
    }

    static func blocksRecording(command: UInt8, payload: Data, apActive: Bool, quarantined: Bool) -> Bool {
        isRecordingRequest(command: command, payload: payload) && (apActive || (payload.first == 1 && quarantined))
    }

    static func ownsReply(command: UInt8, sameTarget: Bool, apActive: Bool, quarantined: Bool) -> Bool {
        command == Gen1Commands.openHotspot && sameTarget && (apActive || quarantined)
    }

    /// The firmware owner confirmed credentials are returned by 0x37, not 0x10.
    /// Call only for an active AP request after outer CRC and sender checks.
    static func credentials(from payload: Data) throws -> Gen1HotspotCredentials {
        let bytes = Array(payload)
        if bytes.count == 1 { throw Gen1APImportError.hotspotRejected(bytes[0]) }
        guard bytes.count >= 3, bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
              let slash = bytes.firstIndex(of: 0x2F), slash > 0, slash < bytes.count - 1,
              let ssid = String(bytes: bytes[..<slash], encoding: .ascii),
              let password = String(bytes: bytes[(slash + 1)...], encoding: .ascii),
              ssid.utf8.count <= 32, (8...63).contains(password.utf8.count) else {
            throw Gen1APImportError.invalidCredentials
        }
        // Preserve bytes exactly. An identifier-shaped SSID is still the SSID.
        return Gen1HotspotCredentials(ssid: ssid, password: password)
    }
}

/// Binding identity survives the intentional BLE interruption during TCP import.
struct Gen1APImportIdentity: Equatable {
    let targetID: UUID
    let token: UUID
    var accountID: String = ""
    var hardwareSN: String? = nil

    func matches(savedID: UUID?, connectedID: UUID?) -> Bool {
        savedID == targetID && (connectedID == nil || connectedID == targetID)
    }

    func matchesAccount(_ current: String?) -> Bool {
        !accountID.isEmpty && current == accountID
    }
}

/// 0x33 arrives in batches of at most 20 names. Do not overwrite earlier batches.
struct Gen1MediaListAccumulator {
    private(set) var names: [String] = []
    private var seen = Set<String>()
    private(set) var requestID = UUID()

    mutating func begin() {
        requestID = UUID()
        names = []
        seen = []
    }

    mutating func append(_ payload: Data) -> Int {
        for name in Gen1FileListParser.parseMediaFiles(payload) where seen.insert(name).inserted {
            names.append(name)
        }
        return names.count
    }
}
