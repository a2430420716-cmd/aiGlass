import AVFoundation
import Foundation

/// 眼镜已连接时，App 内播放统一走眼镜扬声器（系统蓝牙 A2DP/HFP），不强制手机外放。
@MainActor
enum GlassesAudioRouteController {
    enum Intent {
        /// 纯播放（AI 语音、录音回放、引导音乐等）。
        case playback
        /// 边录边播（同声传译等：手机麦 + 眼镜扬声器）。
        case playAndRecord
        /// 仅跟系统音量，不抢路由。
        case ambientVolume
    }

    private(set) static var glassesConnected = false
    private static var routeObserver: NSObjectProtocol?
    private static var didInstallObserver = false
    private static var reconnectTask: Task<Void, Never>?

    static func setGlassesConnected(_ connected: Bool) {
        installRouteObserverIfNeeded()
        let changed = glassesConnected != connected
        glassesConnected = connected
        reconnectTask?.cancel()
        reconnectTask = nil

        guard connected else {
            if changed {
                print("[GlassesAudio] glassesConnected=false")
            }
            return
        }

        // BLE ready 后经典蓝牙 A2DP 常晚几秒才起来，多轮刷新路由。
        reconnectTask = Task { @MainActor in
            for delayNs in [0, 500_000_000, 1_500_000_000, 3_000_000_000, 6_000_000_000, 8_500_000_000] as [UInt64] {
                if delayNs > 0 {
                    try? await Task.sleep(nanoseconds: delayNs)
                }
                guard !Task.isCancelled, glassesConnected else { return }
                // 采集中把 category 掀成 playback 会掐断录音，留给录音方自己处理路由。
                let category = AVAudioSession.sharedInstance().category
                if category == .playAndRecord || category == .record {
                    print("[GlassesAudio] skip route refresh while capturing (\(category.rawValue))")
                    return
                }
                // 已在蓝牙输出上：不重复 setActive，避免打断系统音乐。
                if isOutputOnBluetooth {
                    print("[GlassesAudio] bluetooth output already active")
                    return
                }
                do {
                    try activate(.playback)
                } catch {
                    print("[GlassesAudio] apply on connect failed: \(error.localizedDescription)")
                }
                if isOutputOnBluetooth {
                    print("[GlassesAudio] bluetooth output locked in")
                    return
                }
            }
            print("[GlassesAudio] glassesConnected=true but bluetooth output not yet available")
        }
    }

    /// 各播放/录音入口统一调用，避免再写死 `.defaultToSpeaker`。
    static func activate(_ intent: Intent) throws {
        installRouteObserverIfNeeded()
        let session = AVAudioSession.sharedInstance()

        switch intent {
        case .playback:
            // mixWithOthers：切回首页刷新路由时不打断系统/第三方正在播的音乐。
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // 清掉可能残留的外放强制，让系统回到蓝牙优先路由。
            try? session.overrideOutputAudioPort(.none)

        case .playAndRecord:
            if glassesConnected {
                // 手机麦克风采集 + 蓝牙 A2DP 输出到眼镜；禁止 defaultToSpeaker。
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.allowBluetoothA2DP, .allowBluetoothHFP, .mixWithOthers]
                )
                try? session.overrideOutputAudioPort(.none)
            } else {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .mixWithOthers]
                )
            }

        case .ambientVolume:
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        }

        try session.setActive(true)
        logCurrentRoute(reason: "activate(\(intent))")
    }

    /// 只为读系统音量：保持 session 活跃即可，绝不改 category。
    /// 改成 `.ambient` 会让正在播放的音频被静音拨片掐掉。
    static func activateForVolumeReadOnly() {
        installRouteObserverIfNeeded()
        let session = AVAudioSession.sharedInstance()
        // 冷启动默认是 soloAmbient，此时才需要给一个不抢占的初始 category。
        if session.category == .soloAmbient {
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        // 已有活跃 category 时不重复抢占 AudioSession，避免影响系统音量写入和蓝牙路由。
    }

    /// 当前输出是否已落在蓝牙端口（眼镜典型为 A2DP/HFP）。
    static var isOutputOnBluetooth: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { port in
            switch port.portType {
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                return true
            default:
                return false
            }
        }
    }

    private static func installRouteObserverIfNeeded() {
        guard !didInstallObserver else { return }
        didInstallObserver = true
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            let reasonValue = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor in
                handleRouteChange(reason: reasonValue)
            }
        }
    }

    private static func handleRouteChange(reason: AVAudioSession.RouteChangeReason?) {
        logCurrentRoute(reason: "routeChange(\(String(describing: reason)))")

        // 眼镜仍连着、但输出被切回内置扬声器时，尝试清掉外放强制。
        guard glassesConnected else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let onBuiltInSpeaker = outputs.contains { $0.portType == .builtInSpeaker }
        let onBluetooth = isOutputOnBluetooth
        if onBuiltInSpeaker, !onBluetooth {
            do {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
                try AVAudioSession.sharedInstance().setActive(true)
                logCurrentRoute(reason: "reclaimFromSpeaker")
            } catch {
                print("[GlassesAudio] reclaim from speaker failed: \(error.localizedDescription)")
            }
        }
    }

    private static func logCurrentRoute(reason: String) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { "\($0.portName)[\($0.portType.rawValue)]" }
            .joined(separator: ", ")
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
            .map { "\($0.portName)[\($0.portType.rawValue)]" }
            .joined(separator: ", ")
        print("[GlassesAudio] \(reason) glasses=\(glassesConnected) out=[\(outputs)] in=[\(inputs)]")
    }
}
