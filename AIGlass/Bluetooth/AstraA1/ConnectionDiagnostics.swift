import Foundation

/// A didDisconnect callback proves loss of this app's GATT session, not loss of
/// every Bluetooth profile. Only a fresh system query establishes current BLE
/// presence. Cached READY, earlier peer events and audio routes are context only.
enum DisconnectDiagnosticAssessment: String {
    case systemBLEPresentAppSessionDisconnected
    case systemBLENotObserved
    case queryUnavailable
    case appGATTRecovered
    case superseded

    struct Evidence {
        var isCurrentContext = true
        var isFollowUp = false
        var centralPoweredOn = true
        var systemQueryPerformed = true
        var targetRetrieved = false
        var appReady = false
        var readyObservedAfterDisconnect = false
        var sessionChanged = false
        var historicalSystemConnected = false
        var bluetoothAudioPresent = false
    }

    static func assess(_ evidence: Evidence) -> Self {
        guard evidence.isCurrentContext else { return .superseded }
        if evidence.isFollowUp, evidence.appReady, evidence.readyObservedAfterDisconnect {
            return .appGATTRecovered
        }
        if evidence.isFollowUp, evidence.sessionChanged { return .superseded }
        guard evidence.centralPoweredOn, evidence.systemQueryPerformed else { return .queryUnavailable }
        if evidence.targetRetrieved { return .systemBLEPresentAppSessionDisconnected }
        return .systemBLENotObserved
    }

    var explanation: String {
        switch self {
        case .systemBLEPresentAppSessionDisconnected:
            return "当前系统查询仍发现目标 BLE 连接，本次回调确认 App GATT 会话断开；不能据此判断断开前后的物理链路连续性"
        case .systemBLENotObserved:
            return "当前系统 BLE 查询未发现目标；这不证明眼镜所有蓝牙连接或硬件物理链路均已断开，经典音频另列"
        case .queryUnavailable:
            return "当前无法执行系统 BLE 查询，不能判断目标是否仍连接系统"
        case .appGATTRecovered:
            return "断开回调之后已观察到同一目标重新 GATT READY；这是后续恢复状态"
        case .superseded:
            return "诊断上下文已被换设备、换 central 或新连接会话替代，不将旧掉线结论归于新会话"
        }
    }
}

/// 只描述可观测证据；CoreBluetooth 查询为空、音频路由未选中都不等于系统蓝牙未连接。
enum ConnectionDiagnosticAssessment: String {
    case bluetoothUnavailable
    case noSavedTarget
    case appReady
    case targetSystemConnected
    case bluetoothAudioOnly
    case unconfirmed

    static func assess(
        centralPoweredOn: Bool,
        hasTarget: Bool,
        targetRetrieved: Bool,
        targetAppConnected: Bool,
        targetAppReady: Bool,
        bluetoothAudioPresent: Bool
    ) -> Self {
        guard centralPoweredOn else { return .bluetoothUnavailable }
        guard hasTarget else { return .noSavedTarget }
        if targetAppReady { return .appReady }
        if targetRetrieved || targetAppConnected { return .targetSystemConnected }
        if bluetoothAudioPresent { return .bluetoothAudioOnly }
        return .unconfirmed
    }

    var explanation: String {
        switch self {
        case .bluetoothUnavailable:
            return "手机蓝牙当前不可用，查看 centralState/authorization"
        case .noSavedTarget:
            return "没有已保存目标，不能自动认领其他设备"
        case .appReady:
            return "目标设备 App GATT 已就绪"
        case .targetSystemConnected:
            return "当前确认目标设备已连接系统，App 协议尚未就绪；查看后续 connect/服务发现日志"
        case .bluetoothAudioOnly:
            return "检测到蓝牙音频路由，但未确认目标 GATT 连接；音频设备可能不是目标眼镜"
        case .unconfirmed:
            return "未取得目标当前连接证据；不能据此认定眼镜未连接系统蓝牙"
        }
    }
}

/// 状态变化立即输出；相同快照按时间限频，并保留被合并的轮询次数。
struct ConnectionDiagnosticRateLimiter {
    struct Emission {
        let suppressedSnapshots: Int
        let unchangedSeconds: Int
    }

    private var signature: String?
    private var firstSeen: TimeInterval = 0
    private var lastEmitted: TimeInterval = 0
    private var suppressed = 0

    mutating func record(
        signature next: String,
        uptime: TimeInterval,
        interval: TimeInterval = 10
    ) -> Emission? {
        if signature != next {
            signature = next
            firstSeen = uptime
            lastEmitted = uptime
            let emission = Emission(suppressedSnapshots: suppressed, unchangedSeconds: 0)
            suppressed = 0
            return emission
        }
        guard uptime - lastEmitted >= interval else {
            suppressed += 1
            return nil
        }
        let emission = Emission(
            suppressedSnapshots: suppressed,
            unchangedSeconds: Int(max(0, uptime - firstSeen))
        )
        lastEmitted = uptime
        suppressed = 0
        return emission
    }
}
