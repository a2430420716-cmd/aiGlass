import Combine
import CoreBluetooth
import Foundation
import UIKit

/// 配对扫描阶段展示在列表中的 BLE 设备。
struct DiscoveredBLEDevice: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let rssi: Int
}

/// Astra A1 BLE 连接状态（文档 3.1.3）。
enum AstraA1ConnectionState: Equatable {
    case idle
    case bluetoothUnavailable(String)
    case scanning
    case connecting
    case discoveringServices
    case enablingNotifications
    case ready
    case failed(String)
    case disconnected
}

struct AIVoiceListeningDurationResponse: Equatable {
    let status: UInt8
    let seconds: Int
    let sequence: Int
}

struct VoiceWakeupResponse: Equatable {
    let status: UInt8
    let enabled: Bool
    let sequence: Int
}

/// Astra A1 专用 BLE 管理器。
/// 按协议服务 UUID 识别设备（不依赖广播名，名称会变）。
/// 流程：扫描 → 连接 → 服务发现 → 订阅通知 → 就绪后查询设备信息。
@MainActor
final class AstraA1BleManager: NSObject, ObservableObject {
    @Published private(set) var connectionState: AstraA1ConnectionState = .idle
    @Published private(set) var statusMessage = L10n.t("查找设备中...", "Looking for devices...")
    @Published private(set) var discoveredPairingDevices: [DiscoveredBLEDevice] = []
    @Published private(set) var deviceName: String?
    @Published private(set) var deviceModel: String?
    @Published private(set) var deviceSN: String?
    @Published private(set) var deviceBattery: String?
    @Published private(set) var isBatteryLevelKnown = false
    @Published private(set) var deviceIsCharging = false
    /// 最近一次手动重连的失败原因，供首页卡片区分「未找到设备」与「设备连接失败」。
    @Published private(set) var lastManualReconnectFailure: ManualReconnectFailure?
    /// 系统已连接目标眼镜，但 App GATT 连续软恢复失败；仅此状态允许点卡片执行硬重建。
    @Published private(set) var manualHardReconnectPeripheralID: UUID?
    @Published private(set) var deviceStorage: String?
    @Published private(set) var deviceVersion2800: String?
    @Published private(set) var deviceVersion6350: String?
    private(set) var gen2OtaVersionReports: [String: Gen2OtaVersionReport] = [:]
    private var gen2OtaVersionReportSequence = 0
    @Published private(set) var isQueryingAboutDeviceInfo = false
    @Published private(set) var isQueryingDeviceVersionsAndStorage = false
    @Published private(set) var deviceVersionQueryFailed = false
    /// 眼镜端待导入手机的媒体文件数量（hasnewfile, file_type≠1）。
    @Published private(set) var pendingImportFileCount = 0
    /// 眼镜端待导入 AI 录音数量（hasnewfile, file_type=1）。
    @Published private(set) var pendingRecordingImportFileCount = 0
    /// App 侧是否认为 AI 录音进行中（发了开始命令后到收到录音文件 / 主动停止）。
    @Published private(set) var isAIRecording = false
    /// 全局设备运行状态（蓝牙 getdevstat / devstatus0 / actionrsp0 一上报就改）。
    @Published private(set) var deviceRuntimeStatus: AstraA1BleProtocol.DeviceRuntimeStatus = .unknown
    private(set) var deviceRuntimeStatusReportSequence = 0
    private(set) var lastReportedDeviceRuntimeStatus: AstraA1BleProtocol.DeviceRuntimeStatus = .unknown
    /// 上一次设备运行状态；每次上报前写入，用于判断 PHOTO_TAKING/VIDEO_RECORDING → STANDBY。
    @Published private(set) var previousDeviceRuntimeStatus: AstraA1BleProtocol.DeviceRuntimeStatus = .unknown
    /// 首页拍照/录像按钮状态（由全局状态跳变驱动）。
    @Published private(set) var isTakingPhoto = false
    @Published private(set) var photoCompleted = false
    @Published private(set) var isVideoStarting = false
    @Published private(set) var isVideoRecording = false
    @Published private(set) var isVideoStopping = false
    @Published private(set) var videoCompleted = false
    /// 设备 EQ 音效：0=标准，1=澎湃，2=静谧。
    @Published private(set) var soundEffectMode: UInt8 = 0
    /// 设置页协议回包；进入设置页后主动查询并同步本地缓存。
    @Published private(set) var settingsVideoResolutionProfile: UInt8?
    @Published private(set) var settingsWearDetectionEnabled: Bool?
    @Published private(set) var aiVoiceListeningDurationResponse: AIVoiceListeningDurationResponse?
    @Published private(set) var voiceWakeupResponse: VoiceWakeupResponse?
    @Published private(set) var indicatorBrightness = Gen2IndicatorBrightnessState()
    private var indicatorBrightnessTask: Task<Void, Never>?
    private var indicatorBrightnessInitialQuery: Task<Void, Never>?
    /// factreset0 的 testresult：0=失败，1=成功，2=进行中。
    @Published private(set) var factoryResetResult: UInt8?
    private var unpairFactoryResetConfirmation: FactoryResetConfirmation?
    /// 拍照/录像等动作被拒绝或失败时的提示文案（供 UI 弹窗）。
    @Published var mediaActionAlertMessage: String?
    @Published var mediaActionToastMessage: String?
    /// 拍照进行中（点按后到 PHOTO_TAKING→STANDBY）。
    var photoActionBlocked: Bool { isTakingPhoto }
    /// 已拿到绑定所需的设备信息（或超时降级）。
    @Published private(set) var isDeviceInfoReady = false

    @Published private(set) var deviceGeneration: DeviceGeneration = .unknown
    @Published private(set) var settingsRecordDurationSeconds: Int?
    @Published private(set) var isRecordDurationSettingPending = false
    @Published private(set) var recordDurationSettingResult: Gen1RecordDurationSettingState.Result?
    private var gen1RecordDurationSetting = Gen1RecordDurationSettingState()
    @Published private(set) var deviceSystemName: String?
    @Published private(set) var deviceHardwareAddress: String?
    var deviceCapabilities: DeviceCapabilities { DeviceCapabilities.forGeneration(deviceGeneration) }
    var capabilities: DeviceCapabilities { deviceCapabilities }
    let gen1ControlSubject = PassthroughSubject<Gen1ControlFrame, Never>()
    private var gen1APImportIdentity: Gen1APImportIdentity?
    struct Gen1FirmwareUpgradeIdentity: Equatable {
        let targetID: UUID
        let accountID: String
        let hardwareSN: String?
        let authorizationID: UUID
        let token = UUID()
    }
    private var gen1FirmwareUpgradeIdentity: Gen1FirmwareUpgradeIdentity?
    private var gen1HotspotReplyTarget: UUID?
    private var gen1HotspotReplyQuarantineUntil: TimeInterval = 0
    private lazy var gen1HotspotCleanup = Gen1HotspotCleanup(
        isAuthorized: { [weak self] identity in
            guard let self else { return false }
            return identity.matches(savedID: self.savedPeripheralID(), connectedID: self.connectedPeripheral?.identifier)
                && identity.matchesAccount(self.gen1ImportAccountProvider?(identity.targetID, identity.hardwareSN))
        },
        canSend: { [weak self] targetID in
            guard let self else { return false }
            return self.isReady && self.deviceGeneration == .gen1G5K61
                && self.connectedPeripheral?.identifier == targetID
        },
        send: { [weak self] targetID, command in
            guard let self, self.connectedPeripheral?.identifier == targetID else { return false }
            return self.sendGen1Command(command: command, payload: Data(), hotspotCleanup: true)
        },
        log: { DebugLogStore.logWiFi($0, detail: $1) }
    )
    private var gen1MediaListAccumulator = Gen1MediaListAccumulator()
    var gen1GuideEventSessionID: UUID?
    var gen1GuideEventTargetID: UUID?
    var gen1GuideEventHandler: ((UUID, Date, Int, Int) -> Void)?
    var gen1GuideMediaHandler: ((UUID, Date, UInt8) -> Void)?
    private var gen1VoiceCharacteristic: CBCharacteristic?
    private let gen1ControlDecoder = Gen1ControlStreamDecoder()
    private let gen1VoiceDecoder = Gen1VoiceStreamDecoder()
    private let gen1SequenceTracker = Gen1VoiceSequenceTracker()
    private let gen1TranslationRouter = Gen1TranslationAudioRouter()
    private var gen1FactoryResetGeneration = 0
    private var gen1RecordingStopTimeout: DispatchWorkItem?
    /// Desired step for the owned page; retain across a failed enqueue/reconnect.
    /// Zero also records completion even if the exit packet could not be queued.
    private var gen1GuideStep = 0
    private var gen1GuidePeripheralID: UUID?
    private var gen1OTAPeripheralID: UUID?
    /// Survives GATT handle resets while this flow restores the normal control channel.
    private var gen1OTAVerificationPeripheralID: UUID?

    private var isRestoringGen1OTAConnection: Bool {
        gen1OTAVerificationPeripheralID != nil
            && gen1OTAVerificationPeripheralID == savedPeripheralID()
            && gen1OTAPeripheralID == nil
            && isFirmwareUpgradeFlowBusy
            && !userInitiatedDisconnect
    }

    func isGen1OTAVersionRecoveryCurrent(targetIdentifier: String) -> Bool {
        isRestoringGen1OTAConnection && gen1OTAVerificationPeripheralID?.uuidString == targetIdentifier
    }
    private static let gen1ServiceUUID = CBUUID(string: "AE3A")
    private static let gen1WriteUUID = CBUUID(string: "AE3B")
    private static let gen1ControlUUID = CBUUID(string: "AE3C")
    private static let gen1VoiceUUID = CBUUID(string: "AE3D")
    private static var supportedServiceUUIDs: [CBUUID] {
        [AstraA1BleProtocol.serviceUUID, gen1ServiceUUID]
    }
    private var centralManager: CBCentralManager!
    private var voiceSettingsResponseSequence = 0
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    /// 标准电池服务电量特征（0x2A19），用于可靠读取电量。
    private var batteryLevelCharacteristic: CBCharacteristic?

    private var isServiceDiscovered = false
    private var isNotificationEnabled = false
    /// 协议 notify 特征已订阅成功（电池服务 notify 不算）。
    private var isProtocolNotificationEnabled = false
    private var hasStartedConnect = false
    private var pendingStart = false
    private var pendingCharacteristicDiscoveries = 0
    private var pendingCharacteristicServices: [CBService] = []
    private var isProbingService = false
    /// 首页刷新电量：仅连接并读电量，不走绑定流程。
    private var isBatteryRefreshMode = false
    /// 蓝牙尚未 poweredOn 时，待就绪后再刷新电量。
    private var pendingBatteryRefresh = false
    /// 蓝牙尚未 poweredOn 时收到的账号绑定 serial_number，待就绪后再认领。
    private var pendingBoundSerialNumbers: [String] = []
    private var deviceStatusSyncRetryWorkItem: DispatchWorkItem?
    private var deviceStatusSyncAttempt = 0
    /// 硬件对连上后的指令风暴敏感：getdevstat 最多再补 1 次。
    private let maxDeviceStatusSyncAttempts = 1
    /// 本次连接是否已发过 getdevstat（含重试）。
    private var hasRequestedDeviceStatusThisConnection = false
    /// 初连 getdevinfo 代次；取消旧的 fire-and-forget 定时发送。
    private var initialDeviceInfoQueryGeneration = 0
    private var isInitialDeviceInfoQueryInProgress = false
    private var routineRefreshWorkItem: DispatchWorkItem?
    private var gen1BackgroundQueryGate = Gen1BackgroundQueryGate()
    private var deferredRoutineRetryWorkItem: DispatchWorkItem?
    private var deferredRoutineRetryAt: TimeInterval?
    private var needsFreshGen1FileList = false
    private var isHomeVideoStartInProgress = false
    private var lastGen1ControlReceivedAt: TimeInterval?
    private var lastGen1CommandSent: (command: UInt8, uptime: TimeInterval)?
    private var gen1ControlDiagnosticBudget = BLERawDiagnosticBudget(limit: 256)
    /// 最近一次有效（非 0）电量读数：重连补刷期间先顶上，避免首页闪 0% / 「已连接」。
    private var lastKnownBatteryPercent: Int?
    private var lastKnownBatteryPeripheralID: UUID?
    private var batteryPollingWorkItem: DispatchWorkItem?
    /// 对齐安卓 startBatteryPolling：连上后周期性 getdevinfo batt0。
    private let batteryPollingInterval: TimeInterval = 60
    /// 尚未拿到有效电量时加密轮询，尽快补上首屏读数。
    private let batteryPollingRetryInterval: TimeInterval = 10

    /// 用户主动断开（取消配对 / 退出登录）时不再监听系统蓝牙。
    private var userInitiatedDisconnect = false
    /// 曾经成功连接过：允许断线后交给 iOS 原生自动连接（常驻 connect）。
    private var autoReconnectEnabled = false
    private var reconnectPeripheral: CBPeripheral?

    /// 导入流程等待特定 BLE 响应。
    private var wifiConfigContinuation: CheckedContinuation<AstraA1BleProtocol.WifiConfig, Error>?
    /// 上次 closewifi 时间，用于 toopenwifi 前的冷却等待。
    private var lastWifiCloseAt: Date?
    private static let wifiReopenCooldown: TimeInterval = 1.0
    private var workPathContinuation: CheckedContinuation<String, Error>?
    private var statusContinuation: CheckedContinuation<Bool, Error>?
    private var statusContinuationCommand: String?
    /// 状态回包命令名别名（如 closewifi / closewifi0）。
    private var statusContinuationAliases: Set<String> = []
    /// 拍照/停止录像后等待 hasnewfile 通知。
    private var mediaCaptureContinuation: CheckedContinuation<Void, Error>?
    /// OTA 升级进度等待（otaprogres 达到 100% 后完成）。
    private var otaUpgradeContinuation: CheckedContinuation<Void, Error>?
    private var otaUpgradeProgressHandler: ((Int) -> Void)?
    private var otaUpgradeTimeoutTask: Task<Void, Never>?
    private var otaUpgradeWaitID: UUID?
    private var otaProgressDeadline: Gen2OtaProgressDeadline?
    /// 蓝牙 OTA 前置 DLL 查询/安装等待。
    private var algorithmInfoContinuation: CheckedContinuation<[AstraA1BleProtocol.DeviceAlgorithmInfo], Error>?
    private var dllUpdateContinuation: CheckedContinuation<AstraA1BleProtocol.DLLUpdateResult, Error>?
    private var dllProgressHandler: ((Int) -> Void)?
    /// withoutResponse 写队列：iOS 缓冲满时直接 write 会静默丢包。
    private struct PendingBLEWrite {
        let data: Data
        let packetID: UUID
        let requiresAvailableDevice: Bool
        let redactPayload: Bool
        let gen1Command: UInt8?
    }
    private var pendingBLEWrites: [PendingBLEWrite] = []
    private var activeBLEWritePacketID: UUID?
    private let maxPendingBLEWrites = 64
    /// 通知不足声明长度时尝试补读；仅凭半包不能区分截断与后续分片。
    private var notifyReadInFlight = false
    private var notifyReadRequestID = UUID()
    private var notifyReadWasIssued = false
    /// 限制每条链路的原始诊断数量，避免音频流挤满调试日志。
    private var rawNotifyDiagnosticBudget = BLERawDiagnosticBudget(limit: 256)
    private var notifyReadAttempts = 0
    /// 当前正在补读的命令；换命令要重新计次，避免上一条命令用光重试额度。
    private var notifyReadCommand: String?
    /// 部分固件对通知特征的 read 回 ATT 0x06（Request Not Supported），此时补读无意义。
    private var notifyReadUnsupported = false
    /// 长包被截断时重建链路重协商 MTU：每条链路只做一次，避免反复断连。
    private var isRelinkingForLongPackets = false
    private var hasRelinkedForLongPackets = false
    private let maxNotifyReadAttempts = 6
    /// 立刻 read 常拿回同一截断值，给设备组包留时间。
    private let notifyReadRetryDelay: TimeInterval = 0.2
    /// 关于设备页：串行逐项查询 getdevinfo，避免并发与 MTU 截断丢包。
    private var aboutDeviceInfoPendingTypes: [AstraA1BleProtocol.DevInfoType] = []
    private var aboutDeviceInfoQueryTimeout: DispatchWorkItem?
    private let aboutDeviceInfoQueryTimeoutSeconds: TimeInterval = 2.5
    /// Gen2 getdevinfo 间隔对齐 Android；Gen1串行查询保留原 200ms 间隔。
    private static let gen2GetDevInfoSendIntervalSeconds: TimeInterval = 3.0
    private var getDevInfoSendIntervalSeconds: TimeInterval {
        deviceGeneration == .gen1G5K61 ? 0.2 : Self.gen2GetDevInfoSendIntervalSeconds
    }
    private var versionsStoragePendingTypes: [AstraA1BleProtocol.DevInfoType] = []
    private var versionsStorageQueryTimeout: DispatchWorkItem?
    private var deviceVersionQueryGate = DeviceVersionQueryGate()
    private let versionsStorageQueryTimeoutSeconds: TimeInterval = 2.5
    private var deferredBatteryQuery = false
    private var deferredPendingImportQuery = false
    private var photoCompletedResetTask: Task<Void, Never>?
    private var videoCompletedResetTask: Task<Void, Never>?
    /// 对齐 Android：拍照命令成功 2.5 秒后主动查询 hasnewfile。
    private var homePhotoNewFileQueryWorkItem: DispatchWorkItem?
    /// Track device recording state and the minimum duration for a manual stop; no timed STOP.
    private var homeVideoCapture = HomeVideoCaptureState()

    /// 智能识图传图中：暂停首页例行电量 / hasnewfile，避免写通道抢带宽导致 imgrecdata 丢包。
    private(set) var isAIVisionTransferBusy = false
    /// 对齐 Android DeviceUpgradeStateManager：整个 OTA（含 DLL 前置）期间禁止例行 BLE 查询插入升级命令流。
    private(set) var isFirmwareUpgradeFlowBusy = false
    private var gen2OtaRecovery = Gen2OtaRecoveryState()
    private var gen2OtaLastProgressAt: TimeInterval?

    private var isSerialGetDevInfoInProgress: Bool {
        isQueryingAboutDeviceInfo
            || isQueryingDeviceVersionsAndStorage
            || isInitialDeviceInfoQueryInProgress
    }

    private static let routineRefreshSkipReasons: Set<String> = [
        "aboutDevice",
        "firmwareUpgrade",
        "otaDetail",
        "refreshVersionsAndStorage"
    ]

    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var probeStartWorkItem: DispatchWorkItem?
    private var connectWatchdogWorkItem: DispatchWorkItem?
    private var gattWatchdogPolicy = GATTWatchdogPolicy()
    private var failedGATTRetryGate = GATTRecoveryRetryGate()
    /// A failed attempt may still finish subscribing. Keep its object identities separate
    /// from active handles so an old central or another device cannot restore READY.
    private struct FailedGATTContext {
        let central: CBCentralManager
        let peripheral: CBPeripheral
        let generation: DeviceGeneration
        let write: CBCharacteristic?
        let notify: CBCharacteristic?
        let voice: CBCharacteristic?
    }
    private var failedGATTContext: FailedGATTContext?
    private var discoverServicesWorkItem: DispatchWorkItem?
    /// 自动恢复必须先等旧链路真正断开，再发下一次 connect；防止旧 didDisconnect 打掉新连接。
    private var automaticGATTRecoveryWorkItem: DispatchWorkItem?
    private var automaticGATTRecoveryGeneration = 0
    private var automaticGATTRecoveryCancellationPeripheralID: UUID?
    private var isAutomaticGATTRecoveryInProgress = false
    /// 用户点击失败卡片后，重建整个 CBCentralManager 的单次硬重连。
    private var isManualHardReconnectAttemptInProgress = false
    private var pendingManualHardReconnectPeripheralID: UUID?
    private var manualHardReconnectLookupWorkItem: DispatchWorkItem?
    private var manualHardReconnectLookupAttempt = 0
    /// 硬重建分两段：先等旧 central 的连接释放，再创建无状态恢复标识的新 central。
    private var manualHardReconnectReleaseTimeoutWorkItem: DispatchWorkItem?
    private var manualHardReconnectCentralRebuildWorkItem: DispatchWorkItem?
    private var manualHardReconnectOldCentral: CBCentralManager?
    private var manualHardReconnectOldPeripheral: CBPeripheral?
    /// 断电重连：系统已连但 didConnect 未到时，周期 retrieve + attach。
    private var systemReconnectMonitorWorkItem: DispatchWorkItem?
    /// 系统传输层刚连上时，只给每轮 GATT 认领刷新一次完整宽限期，避免轮询无限续期。
    private var systemTransportGracePeripheralIDs = Set<UUID>()
    /// 已由 retrieveConnectedPeripherals / peerConnected 明确认定为系统层已连接的目标。
    private var systemTransportConnectedPeripheralIDs = Set<UUID>()
    private var connectionDiagnosticLimiters: [String: ConnectionDiagnosticRateLimiter] = [:]
    private struct PeerEventDiagnosticObservation {
        let event: String
        let date: Date
        let uptime: TimeInterval
        let centralID: ObjectIdentifier
    }
    private var peerEventDiagnosticObservations: [UUID: PeerEventDiagnosticObservation] = [:]
    private var disconnectDiagnosticID = UUID()
    private var diagnosticConnectionGeneration: UInt64 = 0
    private var diagnosticReadyObservation: (id: UUID, uptime: TimeInterval)?
    private var didRegisterConnectionEvents = false
    private var gattDiscoveryAttempt = 0
    private var loggedPeripheralIDs = Set<UUID>()
    private var probeCandidates: [ProbeCandidate] = []
    private var probedIDs = Set<UUID>()
    /// 配对弹窗：仅扫描并展示列表，用户点「配对」后再连接。
    private var isPairingSessionActive = false
    private var isManualPairingScan = false
    private var isUserInitiatedPairingConnect = false
    /// 手动重连的失败类型。文案已多语言，UI 不能靠比对字符串区分。
    enum ManualReconnectFailure {
        case notFound
        case connectFailed
    }

    /// 首页卡片点击触发的手动重连扫描（区别于配对弹窗扫描）。
    private var isManualReconnectScan = false
    private var isManualReconnectConnect = false
    private var manualReconnectCandidateIDs: Set<UUID> = []
    private var manualReconnectExpectedName: String?
    private var manualReconnectAllowAnyProtocolDevice = false
    private var manualReconnectScanWorkItem: DispatchWorkItem?
    private let manualReconnectScanTimeoutSeconds: TimeInterval = 15
    private var boundReconnectScanTargetID: UUID?
    private var boundReconnectScanTimeoutWorkItem: DispatchWorkItem?
    private var boundBLEReconnectPolicy = BoundBLEReconnectPolicy()
    private var homeSelectionTargetID: UUID?
    private var homeSelectionRetryPolicies: [UUID: BoundBLEReconnectPolicy] = [:]
    private var boundBLEAttemptFailureCounted = false
    private var boundBLEStopWaitingForRelease = false
    /// 已挂起常驻 connect 的外设；避免监控轮询反复重复 connect 刷屏。
    private var standingConnectPeripheralID: UUID?
    /// 系统传输层已连接、App GATT 却卡在 connecting 时的重建次数。
    private var standingConnectRecoveryCount = 0
    /// 是否允许为已绑定 UUID 挂常驻 connect；缓存不代表 BLE 已连接。
    private var standingConnectAllowed = false
    /// 配对弹窗扫描时按设备名过滤，值为所选 model_name（如 G5T71）。
    private var pairingModelNameFilter: String?
    private var userPairingTargetID: UUID?
    private var userPairingRetryCount = 0
    private let maxUserPairingRetries = 3
    /// 用户点「配对」时若系统层已连接，先断开再以全新连接触发系统配对弹窗。
    private var pendingUserPairingPeripheral: CBPeripheral?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var activeProbeRSSI: Int?

    private let scanTimeoutSeconds: TimeInterval = 30
    private let probeStartDelaySeconds: TimeInterval = 1.5
    /// Each GATT phase gets its own budget; discovery must not consume notification time.
    private let connectWatchdogSeconds: TimeInterval = 15
    /// Android 可 close 后创建全新 BluetoothGatt；iOS 复用同一 CoreBluetooth 外设，需更长恢复时间。
    private let standingConnectRetryIntervalSeconds: TimeInterval = 15
    /// 手机/眼镜重启后，系统蓝牙通常先连接；首次给 App GATT 20 秒认领时间。
    private let systemTransportConnectGraceSeconds: TimeInterval = 20
    /// 首次连接失败后只执行一次软 GATT 重建，随后等待用户点击硬重建。
    private let maxStandingConnectRecoveryAttempts = 1
    private let automaticGATTRecoveryPollSeconds: TimeInterval = 0.25
    private let automaticGATTRecoveryResumeDelaySeconds: TimeInterval = 0.25
    private let manualHardReconnectLookupIntervalSeconds: TimeInterval = 0.5
    private let maxManualHardReconnectLookupAttempts = 10
    private let manualHardReconnectReleaseTimeoutSeconds: TimeInterval = 2
    private let manualHardReconnectCentralRebuildDelaySeconds: TimeInterval = 0.4
    /// 调试开关：系统蓝牙已连接后不自动认领 GATT，必须点首页卡片执行硬重建。
    private let temporarilyRequireManualHardReconnectForTesting = false
    private let maxGATTDiscoveryAttempts = 4
    /// BLE 就绪后等待 iOS 经典蓝牙（音频）系统配对，与 Android connectClassicBluetooth 对齐。
    private let systemPairingGraceSeconds: TimeInterval = 8
    private let minProbeRSSI = -75
    private let savedPeripheralIDKey = "astraA1.ble.peripheralID"
    private let centralRestoreIdentifier = "com.mocoai.astraA1.central"
    private let pendingRecordingCountKey = "astraA1.ble.pendingRecordingCount"
    private let logTag = "[AstraA1BLE]"

    /// 控制台 + 调试浮窗「连接」Tab 双写。
    private func connectLog(
        _ title: String,
        detail: String = "",
        direction: DebugLogStore.Direction = .event
    ) {
        if detail.isEmpty {
            print("\(logTag) \(title)")
        } else {
            print("\(logTag) \(title) \(detail)")
        }
        DebugLogStore.logConnect(title, detail: detail, direction: direction)
    }

    /// 控制台 + 调试浮窗「Wi-Fi」Tab 双写。detail 禁止包含热点密码明文。
    private func wifiLog(
        _ title: String,
        detail: String = "",
        direction: DebugLogStore.Direction = .event
    ) {
        if detail.isEmpty {
            print("\(logTag) [WiFi] \(title)")
        } else {
            print("\(logTag) [WiFi] \(title) \(detail)")
        }
        DebugLogStore.logWiFi(title, detail: detail, direction: direction)
    }

    private func connectStateDescription(_ state: AstraA1ConnectionState) -> String {
        switch state {
        case .idle: return "idle"
        case .bluetoothUnavailable(let message): return "bluetoothUnavailable(\(message))"
        case .scanning: return "scanning"
        case .connecting: return "connecting"
        case .discoveringServices: return "discoveringServices"
        case .enablingNotifications: return "enablingNotifications"
        case .ready: return "ready"
        case .failed(let message): return "failed(\(message))"
        case .disconnected: return "disconnected"
        }
    }

    private func peripheralStateDescription(_ state: CBPeripheralState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
    /// 与实际门禁使用同一查询结果。历史事件标记、音频路由都不单独证明目标当前已连接。
    private func logConnectionGateSnapshot(
        source: String,
        targetID: UUID?,
        retrieved: [CBPeripheral],
        cached: CBPeripheral?,
        decision: String,
        queryPerformed: Bool = true
    ) {
        let targetRetrieved = targetID.map { id in retrieved.contains { $0.identifier == id } } ?? false
        let targetAppConnected = cached?.identifier == targetID && cached?.state == .connected
        let targetAppReady = isReady && connectedPeripheral?.identifier == targetID && targetID != nil
        let audio = GlassesAudioRouteController.connectionDiagnosticSnapshot
        let centralState = centralManager?.state ?? .unknown
        let assessment = ConnectionDiagnosticAssessment.assess(
            centralPoweredOn: centralState == .poweredOn,
            hasTarget: targetID != nil,
            targetRetrieved: targetRetrieved,
            targetAppConnected: targetAppConnected,
            targetAppReady: targetAppReady,
            bluetoothAudioPresent: audio.bluetoothPresent
        )
        let returned = retrieved.map {
            "id=\($0.identifier.uuidString) name=\(($0.name ?? "unknown").debugDescription) state=\(peripheralStateDescription($0.state))"
        }.sorted().joined(separator: "; ")
        let historicalEvent = targetID.map { systemTransportConnectedPeripheralIDs.contains($0) } ?? false
        let detail = """
        diagnosticVersion=1 source=\(source) decision=\(decision)
        assessment=\(assessment.rawValue): \(assessment.explanation)
        centralInitialized=\(centralManager != nil) centralState=\(centralState) (\(centralState.rawValue)) authorization=\(CBManager.authorization.rawValue) appState=\(connectStateDescription(connectionState))
        targetID=\(targetID?.uuidString ?? "none") targetName=\((cached?.name ?? deviceName ?? "unknown").debugDescription)
        serviceFilter=\(Self.supportedServiceUUIDs.map(\.uuidString).joined(separator: ",")) queryPerformed=\(queryPerformed) retrievedCount=\(retrieved.count) targetMatched=\(targetRetrieved)
        retrievedPeripherals=[\(returned)]
        cachedTargetState=\(cached.map { peripheralStateDescription($0.state) } ?? "not_cached") observedSystemConnectionFlag=\(historicalEvent) flagIsHistorical=true
        autoReconnect=\(autoReconnectEnabled) userDisconnect=\(userInitiatedDisconnect) standingAllowed=\(standingConnectAllowed) standingRequest=\(standingConnectPeripheralID?.uuidString ?? "none")
        manualRetryRequired=\(manualHardReconnectPeripheralID != nil) recoveryInProgress=\(isAutomaticGATTRecoveryInProgress) recoveryAttempt=\(standingConnectRecoveryCount)
        \(audio.detail)
        """
        var limiter = connectionDiagnosticLimiters[source] ?? ConnectionDiagnosticRateLimiter()
        let emission = limiter.record(signature: detail, uptime: ProcessInfo.processInfo.systemUptime)
        connectionDiagnosticLimiters[source] = limiter
        guard let emission else { return }
        connectLog(
            "connection gate snapshot",
            detail: detail + "\nunchangedSeconds=\(emission.unchangedSeconds) suppressedSnapshots=\(emission.suppressedSnapshots)"
        )
    }

    /// This diagnostic never changes connection flags or starts a BLE connection.
    /// Capture both sides of the callback race, then recheck once after one second.
    private func recordDisconnectDiagnostics(
        central: CBCentralManager,
        peripheral: CBPeripheral,
        error: NSError?,
        callbackDate: Date,
        callbackUptime: TimeInterval,
        callbackPeripheralState: CBPeripheralState
    ) {
        let incidentID = UUID()
        disconnectDiagnosticID = incidentID
        let generation = diagnosticConnectionGeneration
        let savedID = savedPeripheralID()
        let callbackAppState = "\(UIApplication.shared.applicationState.rawValue)"
        let callbackGATTState = connectStateDescription(connectionState)
        let callbackDetail = """
        callbackAt=\(ISO8601DateFormatter().string(from: callbackDate)) callbackUptime=\(callbackUptime) callbackPeripheralState=\(peripheralStateDescription(callbackPeripheralState))
        errorDomain=\(error?.domain ?? "none") errorCode=\(error.map { String($0.code) } ?? "none") errorDescription=\((error?.localizedDescription ?? "none").debugDescription)
        callbackHandlerAppLifecycleRaw=\(callbackAppState) callbackGATTState=\(callbackGATTState) callbackReadyIsPreCleanup=true
        userInitiated=\(userInitiatedDisconnect) autoReconnect=\(autoReconnectEnabled) otaFlowBusy=\(isFirmwareUpgradeFlowBusy)
        runtime=\(deviceRuntimeStatus.name) videoRecording=\(isVideoRecording) videoStopping=\(isVideoStopping) pendingWriteFragments=\(pendingBLEWrites.count)
        lastGen1Command=\(lastGen1CommandSent.map { String(format: "0x%02X", $0.command) } ?? "none") lastGen1CommandAgeSeconds=\(lastGen1CommandSent.map { String(format: "%.3f", callbackUptime - $0.uptime) } ?? "none") lastGen1ControlAgeSeconds=\(lastGen1ControlReceivedAt.map { String(format: "%.3f", callbackUptime - $0) } ?? "none")
        """
        emitDisconnectDiagnosticSnapshot(
            central: central, peripheral: peripheral, incidentID: incidentID,
            callbackUptime: callbackUptime, generation: generation,
            callbackDetail: callbackDetail, isFollowUp: false
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak central, weak peripheral] in
            guard let self, let central, let peripheral,
                  self.disconnectDiagnosticID == incidentID else { return }
            let currentSavedID = self.savedPeripheralID()
            let targetChanged = self.connectedPeripheral.map { $0.identifier != peripheral.identifier } == true
                || self.pendingUserPairingPeripheral.map { $0.identifier != peripheral.identifier } == true
                || (currentSavedID != savedID && currentSavedID != peripheral.identifier)
            guard central === self.centralManager, !targetChanged else {
                self.connectLog("disconnect diagnostic follow-up skipped", detail: "incident=\(incidentID.uuidString) id=\(peripheral.identifier.uuidString) assessment=superseded reason=central-or-target-changed")
                return
            }
            self.emitDisconnectDiagnosticSnapshot(
                central: central, peripheral: peripheral, incidentID: incidentID,
                callbackUptime: callbackUptime, generation: generation,
                callbackDetail: callbackDetail, isFollowUp: true
            )
        }
    }

    private func emitDisconnectDiagnosticSnapshot(
        central: CBCentralManager,
        peripheral: CBPeripheral,
        incidentID: UUID,
        callbackUptime: TimeInterval,
        generation: UInt64,
        callbackDetail: String,
        isFollowUp: Bool
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let queryPerformed = central.state == .poweredOn
        let retrieved = queryPerformed
            ? central.retrieveConnectedPeripherals(withServices: Self.supportedServiceUUIDs) : []
        let targetRetrieved = retrieved.contains { $0.identifier == peripheral.identifier }
        let targetReady = isReady && connectedPeripheral?.identifier == peripheral.identifier
            && connectedPeripheral?.state == .connected
        let readyAfterDisconnect = diagnosticReadyObservation.map {
            $0.id == peripheral.identifier && $0.uptime > callbackUptime
        } ?? false
        let audio = GlassesAudioRouteController.connectionDiagnosticSnapshot
        let historicalFlag = systemTransportConnectedPeripheralIDs.contains(peripheral.identifier)
        let currentTargetMatches = connectedPeripheral.map { $0.identifier == peripheral.identifier } ?? true
        let assessment = DisconnectDiagnosticAssessment.assess(.init(
            isCurrentContext: central === centralManager && currentTargetMatches,
            isFollowUp: isFollowUp,
            centralPoweredOn: central.state == .poweredOn,
            systemQueryPerformed: queryPerformed,
            targetRetrieved: targetRetrieved,
            appReady: targetReady,
            readyObservedAfterDisconnect: readyAfterDisconnect,
            sessionChanged: diagnosticConnectionGeneration != generation,
            historicalSystemConnected: historicalFlag,
            bluetoothAudioPresent: audio.bluetoothPresent
        ))
        let returned = retrieved.map {
            "id=\($0.identifier.uuidString) state=\(peripheralStateDescription($0.state))"
        }.sorted().joined(separator: "; ")
        let peer = peerEventDiagnosticObservations[peripheral.identifier].map {
            "event=\($0.event) at=\(ISO8601DateFormatter().string(from: $0.date)) ageSeconds=\(String(format: "%.3f", max(0, now - $0.uptime))) sameCentral=\($0.centralID == ObjectIdentifier(central)) historicalOnly=true"
        } ?? "none"
        connectLog("disconnect evidence snapshot", detail: """
        diagnosticVersion=2 incident=\(incidentID.uuidString) phase=\(isFollowUp ? "after-1s" : "callback") elapsedSeconds=\(String(format: "%.3f", max(0, now - callbackUptime)))
        assessment=\(assessment.rawValue): \(assessment.explanation)
        targetID=\(peripheral.identifier.uuidString) centralState=\(central.state.rawValue) appLifecycleRaw=\(UIApplication.shared.applicationState.rawValue) lifecycleMap=0:active,1:inactive,2:background
        \(callbackDetail)
        currentPeripheralState=\(peripheralStateDescription(peripheral.state)) currentGATTState=\(connectStateDescription(connectionState)) currentReady=\(targetReady) readyObservedAfterDisconnect=\(readyAfterDisconnect)
        callbackSession=\(generation) currentSession=\(diagnosticConnectionGeneration)
        systemQueryPerformed=\(queryPerformed) serviceFilter=\(Self.supportedServiceUUIDs.map(\.uuidString).joined(separator: ",")) targetMatched=\(targetRetrieved) retrievedPeripherals=[\(returned)]
        observedSystemConnectionFlag=\(historicalFlag) flagIsHistorical=true lastPeerEvent=[\(peer)]
        \(audio.detail)
        evidenceLimit=system_query_is_a_point_in_time_and_service_filtered; audio_is_separate_and_target_unverified; no_public_API_proof_of_all_physical_Bluetooth_links
        """, direction: .received)
    }

    /// 当前会话身份对应的外设；换外设或断开时清空 getdevinfo 缓存，避免首页卡片对错眼镜。
    private var identityPeripheralID: UUID?

    private struct ProbeCandidate {
        let peripheral: CBPeripheral
        let rssi: Int
    }

    override init() {
        super.init()
        // 录音 pending 跨进页保留：hasnewfile 主动查询常只回媒体 type=0。
        let savedPending = UserDefaults.standard.integer(forKey: pendingRecordingCountKey)
        if savedPending > 0 {
            pendingRecordingImportFileCount = savedPending
        }
        // 已绑定设备优先接管系统连接，否则主动挂起目标 BLE 重连。
        let hasSavedPeripheral = UserDefaults.standard.string(forKey: savedPeripheralIDKey)
            .flatMap(UUID.init(uuidString:)) != nil
        autoReconnectEnabled = hasSavedPeripheral
        standingConnectAllowed = false
        _ = prepareCentralManager()
    }

    /// Automatic entry points may restore existing authorization, never request it.
    /// Only pairing and an explicit bound-device connect action pass `true`.
    @discardableResult
    private func prepareCentralManager(allowAuthorizationRequest: Bool = false) -> Bool {
        let authorization: BluetoothActivationPolicy.Authorization
        switch CBManager.authorization {
        case .allowedAlways: authorization = .allowed
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .restricted: authorization = .restricted
        @unknown default: authorization = .restricted
        }
        let activated = BluetoothActivationPolicy.activate(
            central: &centralManager, authorization: authorization,
            userInitiated: allowAuthorizationRequest
        ) {
            CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionRestoreIdentifierKey: centralRestoreIdentifier]
            )
        }
        if !activated, allowAuthorizationRequest {
            updateState(.bluetoothUnavailable(L10n.t("请在设置中允许蓝牙权限", "Allow Bluetooth in Settings")))
        }
        return activated
    }

    var isReady: Bool {
        if case .ready = connectionState { return true }
        return false
    }

    /// Business commands require the current BLE device to have a real home device card.
    /// The app injects the card lookup; an unconfigured manager must deny operations.
    var deviceCardPresenceProvider: (() -> Bool)?
    /// Import identity lookup must survive BLE dropping, but not logout or unbinding.
    var gen1ImportAccountProvider: ((UUID, String?) -> String?)?
    private(set) var gen1ImportAuthorizationID = UUID()

    func gen1ImportAccount(for targetID: UUID) -> String? {
        guard savedPeripheralID() == targetID else { return nil }
        let sn = connectedPeripheral?.identifier == targetID ? deviceSN : nil
        return gen1ImportAccountProvider?(targetID, sn ?? cachedHardwareSN(forSerialNumber: targetID.uuidString))
    }

    var isDeviceAvailable: Bool {
        DeviceAvailabilityPolicy.canOperate(
            isBluetoothReady: isReady,
            hasCorrespondingCard: deviceCardPresenceProvider?() ?? false
        )
    }

    var currentPeripheralName: String? { connectedPeripheral?.name }

    /// Passive snapshot for recording/connection correlation; never starts a reconnect.
    var connectionAvailabilityDiagnosticDetail: String {
        "state=\(connectionState) bleReady=\(isReady) matchingCard=\(deviceCardPresenceProvider?() ?? false) target=\(connectedPeripheral?.identifier.uuidString ?? "nil") saved=\(savedPeripheralUUIDString ?? "nil") nativeState=\(connectedPeripheral.map { peripheralStateDescription($0.state) } ?? "nil") generation=\(deviceGeneration.rawValue)"
    }

    func matchesCurrentDevice(serialNumber: String?, hardwareSN: String?) -> Bool {
        DeviceAvailabilityPolicy.matches(
            serialNumber: serialNumber,
            hardwareSN: hardwareSN,
            currentPeripheralID: connectedPeripheral?.identifier.uuidString,
            currentHardwareSN: deviceSN
        )
    }

    @discardableResult
    private func ensureDeviceAvailable(for operation: String) -> Bool {
        let hasDeviceCard = deviceCardPresenceProvider?() ?? false
        guard isReady, hasDeviceCard else {
            connectLog(
                "device operation rejected",
                detail: "operation=\(operation) bleReady=\(isReady) matchingDeviceCard=\(hasDeviceCard)"
            )
            return false
        }
        return true
    }

    /// Android DeviceStatusManager.isIdleStatus：STANDBY、UNKNOWN 都允许开始新动作。
    var isDeviceRuntimeIdle: Bool {
        deviceRuntimeStatus == .standby || deviceRuntimeStatus == .unknown
    }

    /// 智能图像识别 BLE 回包回调（imgrecrsp0 / imgrecdata）。
    var aiVisionNotifyHandler: ((String, Data) -> Void)?
    /// AI 语音回包（aivoicests / aivoicedat / aivoicetur）。
    var aiVoiceNotifyHandler: ((String, Data) -> Void)?
    /// 对话翻译眼镜录音回包（trslatests / trslatedat）。
    var translationVoiceNotifyHandler: ((String, Data) -> Void)?
    /// 识图传图中设备从 AI_VISION_OPERATING → STANDBY（末包可能丢，用已收包收尾）。
    var aiVisionDeviceIdleHandler: (() -> Void)?
    /// 新手引导设备操作事件（guideevt00 的 eventType）。
    var guideEventHandler: ((UInt8) -> Void)?

    /// 是否正在建立 GATT 连接（用于首页「正在连接...」提示）。
    var isConnectionInProgress: Bool {
        if isBatteryRefreshMode { return true }
        switch connectionState {
        case .connecting, .discoveringServices, .enablingNotifications:
            return true
        default:
            return false
        }
    }

    var isBoundConnectionSearchInProgress: Bool {
        boundReconnectScanTargetID != nil || isManualReconnectScan
    }

    /// 用户点击硬重连后，旧 central 尚未释放或新 central 尚未创建。
    private var isManualHardReconnectCentralTransitionInProgress: Bool {
        manualHardReconnectOldCentral != nil
            || manualHardReconnectCentralRebuildWorkItem != nil
    }

    /// 解析后的电量百分比（0-100）。未从 getdevinfo batt0 拿到真实读数前返回 nil。
    var deviceBatteryPercent: Int? {
        guard isBatteryLevelKnown, let deviceBattery else { return nil }
        return Int(deviceBattery.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Both main and Bluetooth firmware use the threshold for the connected generation.
    var firmwareUpgradeMinimumBatteryPercent: Int {
        deviceGeneration == .gen2
            ? FirmwareUpgradeBatteryPolicy.gen2MinimumPercent
            : FirmwareUpgradeBatteryPolicy.gen1MinimumPercent
    }

    /// Charging does not bypass the generation-specific battery requirement.
    var firmwareUpgradeBatteryAlertMessage: String? {
        guard let percent = deviceBatteryPercent, (0...100).contains(percent) else {
            return L10n.t("正在读取眼镜电量，请稍后再试。", "Reading glasses battery. Please try again later.")
        }
        let minimum = firmwareUpgradeMinimumBatteryPercent
        guard FirmwareUpgradeBatteryPolicy.allowsUpgrade(percent: percent, minimumPercent: minimum) else {
            return L10n.t("眼镜电量不足（当前\(percent)%），请充电至 \(minimum)% 或以上再升级。", "Glasses battery is too low (\(percent)%). Charge to at least \(minimum)% before updating.")
        }
        return nil
    }

    /// 拍照、开始录像、导入文件、AI 录音、智能识图共用低电量门禁；未知电量不误拦截。
    var isBatteryTooLowForMedia: Bool {
        guard let percent = deviceBatteryPercent else { return false }
        return percent <= 15
    }

    var lowBatteryMediaMessage: String {
        L10n.t("眼镜电量过低，请充电后再试", "Glasses battery is too low. Charge and try again.")
    }

    /// 首页进入：系统蓝牙已连接才接管 GATT；否则只监听系统连接事件。
    func ensureConnected(reason: String = "") {
        guard prepareCentralManager() else { return }
        guard !isPairingSessionActive else {
            connectLog("background connection deferred: pairing owns BLE", detail: "reason=\(reason)")
            return
        }
        if stopBoundReconnectIfExhausted() { return }
        guard gen1OTAPeripheralID == nil else { return }
        if !isReady, reason == "gen1-ota-version-verification" || isRestoringGen1OTAConnection {
            // Version verification owns this reconnect. Falling through to a battery
            // refresh changes scanning to disconnected, so didDiscover ignores the
            // target even while CoreBluetooth continues scanning.
            if !isConnectionInProgress, !centralManager.isScanning, let id = savedPeripheralID() {
                _ = reconnectBoundDevice(boundSerialNumbers: [id.uuidString], reason: reason)
            }
            return
        }
        if savedPeripheralID() != nil, !userInitiatedDisconnect {
            // 进 App/回前台恢复已绑定目标的 BLE 连接。
            autoReconnectEnabled = true
        }
        connectLog(
            "ensureConnected",
            detail: "reason=\(reason) state=\(connectStateDescription(connectionState)) inProgress=\(isConnectionInProgress) saved=\(savedPeripheralID()?.uuidString ?? "nil") standingAllowed=\(standingConnectAllowed) autoReconnect=\(autoReconnectEnabled) userDisconnect=\(userInitiatedDisconnect)",
            direction: .sent
        )
        guard !isManualHardReconnectCentralTransitionInProgress else {
            connectLog("ensureConnected deferred: rebuilding central", detail: "reason=\(reason)")
            return
        }
        if case .ready = connectionState {
            pendingBatteryRefresh = false
            guard !Self.routineRefreshSkipReasons.contains(reason) else {
                connectLog("ensureConnected already ready, skip routine refresh", detail: "reason=\(reason)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.scheduleRoutineDeviceRefresh()
            }
            connectLog("ensureConnected already ready, schedule routine refresh", detail: "reason=\(reason)")
            return
        }

        // 系统蓝牙已连接时，优先直接接管 GATT（connect 回调可能不会触发）
        if attachToAlreadyConnectedPeripheralIfPossible(source: "ensureConnected") {
            connectLog("ensureConnected evaluated system connection", detail: "reason=\(reason) state=\(connectStateDescription(connectionState))")
            return
        }

        // 已在连接中，不重复发起
        if isConnectionInProgress {
            connectLog("ensureConnected skipped: connection already in progress", detail: "reason=\(reason)")
            return
        }

        refreshBatteryLevel()
    }

    /// 首页显示时刷新电量：已连接则查询，否则恢复已绑定目标的 BLE 连接。
    func refreshBatteryLevel() {
        guard prepareCentralManager() else { return }
        guard !isPairingSessionActive else { return }
        if stopBoundReconnectIfExhausted() { return }
        guard gen1OTAPeripheralID == nil else { return }
        if isRestoringGen1OTAConnection, !isReady {
            ensureConnected(reason: "gen1-ota-version-verification")
            return
        }
        guard !isManualHardReconnectCentralTransitionInProgress else {
            connectLog("refreshBatteryLevel deferred: rebuilding central")
            return
        }
        if case .ready = connectionState {
            pendingBatteryRefresh = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.scheduleRoutineDeviceRefresh()
            }
            return
        }

        // 优先尝试接管系统已连接的目标，再完成 App 的 GATT 初始化。
        if attachToAlreadyConnectedPeripheralIfPossible(source: "refreshBatteryLevel") {
            connectLog("refreshBatteryLevel attached system-connected peripheral")
            return
        }

        // 已在连接流程中，不重复发起
        if isConnectionInProgress {
            connectLog("refreshBatteryLevel skipped: connection already in progress")
            return
        }

        guard centralManager.state == .poweredOn else {
            pendingBatteryRefresh = true
            connectLog("refreshBatteryLevel deferred: bluetooth not powered on")
            return
        }

        pendingBatteryRefresh = false
        isBatteryRefreshMode = true
        hasStartedConnect = false
        isServiceDiscovered = false
        isNotificationEnabled = false
        isProtocolNotificationEnabled = false
        cancelDeviceStatusSyncRetry()
        writeCharacteristic = nil
        notifyCharacteristic = nil

        if let id = savedPeripheralID(),
           let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first {
            connectLog(
                "refreshBatteryLevel found saved peripheral",
                detail: "id=\(id.uuidString) peripheralState=\(peripheralStateDescription(peripheral.state))"
            )
            userInitiatedDisconnect = false
            autoReconnectEnabled = true
            reconnectPeripheral = peripheral

            // 系统层已是 connected，直接恢复特征
            if peripheral.state == .connected {
                attachToConnectedPeripheral(peripheral)
                return
            }

            // 未取得目标的系统连接证据：保留身份并监听，不主动发起 GATT connect。
            isBatteryRefreshMode = false
            standingConnectAllowed = false
            updateState(.disconnected)
            startSystemReconnectMonitor()
            return
        }

        isBatteryRefreshMode = false
        if savedPeripheralID() != nil {
            // 系统尚未缓存该外设对象：保持监听，待系统蓝牙连接后回调
            autoReconnectEnabled = true
            userInitiatedDisconnect = false
            updateState(.disconnected)
            connectLog("refreshBatteryLevel: no peripheral object yet, waiting for system connection", detail: "saved=\(savedPeripheralID()?.uuidString ?? "nil")")
        } else {
            connectLog("refreshBatteryLevel: no peripheral available")
        }
    }

    /// 已绑定 UUID 可挂起一次 iOS connect 等设备可达；真实失败最多尝试三次。
    /// 收到传输层连接证据后才启用 GATT 看门狗，等待期间 UI 显示「正在连接...」。
    /// 另起轮询：眼镜关机再开时，系统 A2DP 常先连上，但 App 层 didConnect 可能迟迟不来，
    /// 需主动 retrieveConnectedPeripherals 再 attach（切 Tab 触发 ensureConnected 也能修好，是同一路径）。
    private func armSystemAutoConnect(
        _ peripheral: CBPeripheral,
        force: Bool = false,
        systemTransportObserved: Bool = false
    ) {
        if stopBoundReconnectIfExhausted() { return }
        guard !isManualHardReconnectCentralTransitionInProgress else {
            connectLog(
                "standing connect deferred: rebuilding central",
                detail: "id=\(peripheral.identifier.uuidString)"
            )
            return
        }
        guard !userInitiatedDisconnect, autoReconnectEnabled else {
            connectLog(
                "standing connect blocked",
                detail: "force=\(force) userDisconnect=\(userInitiatedDisconnect) autoReconnect=\(autoReconnectEnabled) id=\(peripheral.identifier.uuidString)"
            )
            return
        }
        // Failed sessions are revalidated separately; do not start an unbounded connect loop.
        guard manualHardReconnectPeripheralID == nil || isManualHardReconnectAttemptInProgress else {
            connectLog(
                "standing connect skipped: waiting for manual hard reconnect",
                detail: "id=\(peripheral.identifier.uuidString)"
            )
            return
        }
        // BLE 已完整就绪时无需再次 connect。同一连接重复 connect 会产生延迟 didConnect，
        // 把 ready 状态重新推进 connecting，并触发 15 秒 watchdog 无限服务发现。
        if case .ready = connectionState,
           connectedPeripheral?.identifier == peripheral.identifier {
            reconnectPeripheral = connectedPeripheral ?? peripheral
            standingConnectAllowed = true
            standingConnectPeripheralID = nil
            connectLog(
                "standing connect skipped: GATT already ready",
                detail: "id=\(peripheral.identifier.uuidString)"
            )
            return
        }
        guard !isAutomaticGATTRecoveryInProgress else {
            connectLog(
                "standing connect deferred: GATT recovery in progress",
                detail: "id=\(peripheral.identifier.uuidString)"
            )
            return
        }
        guard force || standingConnectAllowed else {
            connectLog("standing connect skipped: waiting for user tap", detail: "id=\(peripheral.identifier.uuidString)")
            return
        }
        if force { standingConnectAllowed = true }
        guard centralManager.state == .poweredOn else {
            pendingBatteryRefresh = true
            connectLog("standing connect deferred: bluetooth not powered on", detail: "id=\(peripheral.identifier.uuidString)")
            return
        }
        let requestedID = peripheral.identifier
        if systemTransportObserved || peripheral.state == .connected {
            systemTransportConnectedPeripheralIDs.insert(requestedID)
        }
        let systemPeripheral = systemConnectedPeripheral(matching: requestedID)
        // Classic audio can reconnect without BLE. A saved binding authorizes a BLE
        // connect request; retrieveConnectedPeripherals is an optimization, not a gate.
        guard savedPeripheralID() == requestedID else {
            standingConnectAllowed = false
            reconnectPeripheral = peripheral
            if !isPairingSessionActive {
                updateState(.disconnected)
            }
            connectLog(
                "standing connect blocked: target not bound",
                detail: "id=\(requestedID.uuidString) cachedPeripheralState=\(peripheralStateDescription(peripheral.state))"
            )
            startSystemReconnectMonitor()
            return
        }
        let peripheral = systemPeripheral ?? peripheral
        if shouldRequireTemporaryManualHardReconnect(for: peripheral) {
            requireTemporaryManualHardReconnect(for: peripheral, source: "armSystemAutoConnect")
            return
        }
        if boundReconnectScanTargetID != nil { stopScan() }
        reconnectPeripheral = peripheral
        connectedPeripheral = peripheral
        peripheral.delegate = self
        if !isConnectionInProgress {
            updateState(.connecting)
        }
        let shouldRefreshSystemTransportGrace = systemTransportObserved
            && !systemTransportGracePeripheralIDs.contains(peripheral.identifier)
        if shouldRefreshSystemTransportGrace {
            systemTransportGracePeripheralIDs.insert(peripheral.identifier)
            connectLog(
                "system transport connected; extend GATT claim grace",
                detail: "id=\(peripheral.identifier.uuidString) seconds=\(systemTransportConnectGraceSeconds) peripheralState=\(peripheralStateDescription(peripheral.state))"
            )
        }
        // Keep one native request pending while the bound glasses wake or return.
        // GATT claiming is timed only after actual BLE transport evidence appears.
        if standingConnectPeripheralID != peripheral.identifier {
            boundBLEAttemptFailureCounted = false
            standingConnectPeripheralID = peripheral.identifier
            savePeripheralID(peripheral.identifier)
            connectLog(
                "arm iOS auto-connect (standing)",
                detail: "id=\(peripheral.identifier.uuidString) peripheralState=\(peripheralStateDescription(peripheral.state)) force=\(force)",
                direction: .sent
            )
            centralManager.connect(peripheral, options: nil)
            if !isReady {
                startConnectWatchdog(
                    for: peripheral,
                    timeoutOverride: shouldRefreshSystemTransportGrace
                        ? systemTransportConnectGraceSeconds
                        : nil
                )
            }
        } else {
            connectLog(
                "standing connect already armed",
                detail: "id=\(peripheral.identifier.uuidString) peripheralState=\(peripheralStateDescription(peripheral.state))"
            )
            if !isReady,
               peripheral.state == .connecting,
               (shouldRefreshSystemTransportGrace || connectWatchdogWorkItem == nil),
               !boundBLEReconnectPolicy.isExhausted {
                startConnectWatchdog(
                    for: peripheral,
                    timeoutOverride: shouldRefreshSystemTransportGrace
                        ? systemTransportConnectGraceSeconds
                        : nil
                )
            }
        }
        // 已 ready 时只挂站岗 connect，不启轮询（markReady 也会走这里）。
        if case .ready = connectionState { return }
        startSystemReconnectMonitor()
    }

    /// 账号绑定 serial_number（iOS 外设 UUID）或本地已保存外设 ID，供首页卡片精确匹配。
    var savedPeripheralUUIDString: String? {
        savedPeripheralID()?.uuidString
    }

    /// UI 只能在已进入失败确认点时拿到可点击 ID。
    /// 即使 ID 在一次状态切换中短暂存在，connecting 也不会暴露点击入口。
    var manualHardReconnectPeripheralUUIDString: String? {
        guard case .failed = connectionState else { return nil }
        return manualHardReconnectPeripheralID?.uuidString
    }

    /// `retrievePeripherals` 只代表系统缓存过外设，不能证明「设置 > 蓝牙」当前已连接。
    /// 此查询用于系统连接接管和 GATT 故障恢复，不作为已绑定 BLE 主动重连的前提。
    private func systemConnectedPeripheral(matching id: UUID) -> CBPeripheral? {
        guard let centralManager, centralManager.state == .poweredOn else { return nil }
        let connected = centralManager.retrieveConnectedPeripherals(
            withServices: Self.supportedServiceUUIDs
        )
        if let peripheral = connected.first(where: { $0.identifier == id }) {
            systemTransportConnectedPeripheralIDs.insert(id)
            logConnectionGateSnapshot(
                source: "systemConnectionGate", targetID: id, retrieved: connected,
                cached: peripheral, decision: "allow_target_in_system_query"
            )
            return peripheral
        }
        let cached = centralManager.retrievePeripherals(withIdentifiers: [id]).first
            ?? reconnectPeripheral.flatMap { $0.identifier == id ? $0 : nil }
        let observed = systemTransportConnectedPeripheralIDs.contains(id)
        logConnectionGateSnapshot(
            source: "systemConnectionGate", targetID: id, retrieved: connected, cached: cached,
            decision: observed && cached != nil
                ? "allow_using_historical_system_connection_flag"
                : "block_no_system_connection_evidence"
        )
        guard observed else { return nil }
        return cached
    }

    /// Manager 硬重建后必须由新 Manager 重新确认，不能沿用旧连接事件留下的标记。
    private func freshlyRetrievedSystemConnectedPeripheral(matching id: UUID) -> CBPeripheral? {
        guard let centralManager, centralManager.state == .poweredOn else { return nil }
        let connected = centralManager.retrieveConnectedPeripherals(
            withServices: Self.supportedServiceUUIDs
        )
        let cached = centralManager.retrievePeripherals(withIdentifiers: [id]).first
        logConnectionGateSnapshot(
            source: "freshCentralSystemQuery", targetID: id, retrieved: connected, cached: cached,
            decision: connected.contains { $0.identifier == id }
                ? "allow_fresh_system_connection" : "wait_fresh_system_connection"
        )
        guard let peripheral = connected.first(where: { $0.identifier == id }) else { return nil }
        systemTransportConnectedPeripheralIDs.insert(id)
        return peripheral
    }

    private func clearManualHardReconnectRequirement(reason: String) {
        guard manualHardReconnectPeripheralID != nil else { return }
        connectLog(
            "clear manual hard reconnect requirement",
            detail: "reason=\(reason) id=\(manualHardReconnectPeripheralID?.uuidString ?? "nil")"
        )
        manualHardReconnectPeripheralID = nil
    }

    /// Reuse only a fully subscribed, still-current failed session. Otherwise retry GATT
    /// initialization after a bounded cooldown, without rebuilding the central in a loop.
    @discardableResult
    private func recoverFailedGATTIfPossible(source: String, allowRetry: Bool) -> Bool {
        if stopBoundReconnectIfExhausted() { return false }
        guard case .failed = connectionState,
              let context = failedGATTContext,
              context.central === centralManager,
              manualHardReconnectPeripheralID == context.peripheral.identifier,
              savedPeripheralID() == context.peripheral.identifier,
              autoReconnectEnabled, !userInitiatedDisconnect,
              gen1OTAPeripheralID == nil, !isFirmwareUpgradeFlowBusy,
              !isPairingSessionActive, !isManualHardReconnectAttemptInProgress,
              !isManualHardReconnectCentralTransitionInProgress,
              !isAutomaticGATTRecoveryInProgress,
              let peripheral = freshlyRetrievedSystemConnectedPeripheral(matching: context.peripheral.identifier) else { return false }

        if peripheral.state == .connected, peripheral === context.peripheral,
           context.generation != .unknown,
           let write = context.write, let notify = context.notify,
           let service = write.service,
           (peripheral.services ?? []).contains(where: { $0 === service }),
           Self.supportedServiceUUIDs.contains(service.uuid),
           (service.characteristics ?? []).contains(where: { $0 === write }),
           (service.characteristics ?? []).contains(where: { $0 === notify }),
           notify.isNotifying,
           context.generation != .gen1G5K61 || context.voice.map({ voice in
               voice.isNotifying && (service.characteristics ?? []).contains(where: { $0 === voice })
           }) == true {
            connectedPeripheral = peripheral
            reconnectPeripheral = peripheral
            peripheral.delegate = self
            assignCharacteristics(from: peripheral.services ?? [])
            guard writeCharacteristic === write, notifyCharacteristic === notify,
                  deviceGeneration == context.generation, protocolNotificationsReady else {
                resetConnectionHandles(preserveFailedRecoveryBudget: true)
                failedGATTContext = context
                return false
            }
            isServiceDiscovered = true
            isProtocolNotificationEnabled = true
            isNotificationEnabled = true
            connectLog("failed GATT recovered from verified subscriptions", detail: "source=\(source) id=\(peripheral.identifier.uuidString)")
            markReadyIfNeeded()
            return true
        }

        guard allowRetry, failedGATTRetryGate.claimRetry(now: ProcessInfo.processInfo.systemUptime) else { return false }
        connectLog("failed GATT retry after cooldown", detail: "source=\(source) id=\(peripheral.identifier.uuidString) retry=\(failedGATTRetryGate.attempts)")
        clearManualHardReconnectRequirement(reason: "fresh system connection revalidated")
        resetConnectionHandles(preserveFailedRecoveryBudget: true)
        boundBLEAttemptFailureCounted = false
        connectedPeripheral = peripheral
        reconnectPeripheral = peripheral
        peripheral.delegate = self
        standingConnectAllowed = true
        if peripheral.state == .connected {
            beginDiscoverServices(on: peripheral, reason: "failed-session-recheck")
        } else {
            armSystemAutoConnect(peripheral, force: true, systemTransportObserved: true)
        }
        startSystemReconnectMonitor()
        return true
    }

    private func shouldRequireTemporaryManualHardReconnect(for peripheral: CBPeripheral) -> Bool {
        guard temporarilyRequireManualHardReconnectForTesting,
              !isManualHardReconnectAttemptInProgress,
              !isPairingSessionActive,
              !isUserInitiatedPairingConnect,
              let savedID = savedPeripheralID() else { return false }
        return peripheral.identifier == savedID
    }

    /// 临时测试入口。调用方必须已经通过 retrieveConnectedPeripherals / peerConnected
    /// 确认系统传输层连接，不能仅凭 retrievePeripherals 缓存进入可点击状态。
    private func requireTemporaryManualHardReconnect(
        for peripheral: CBPeripheral,
        source: String
    ) {
        guard shouldRequireTemporaryManualHardReconnect(for: peripheral) else { return }
        if case .failed = connectionState,
           manualHardReconnectPeripheralID == peripheral.identifier {
            return
        }
        cancelAutomaticGATTRecovery(reason: "temporary manual-only test", resetAttempts: true)
        stopSystemReconnectMonitor()
        cancelConnectWatchdog()
        cancelDiscoverServicesWorkItem()
        standingConnectAllowed = false
        standingConnectPeripheralID = nil
        hasStartedConnect = false
        isBatteryRefreshMode = false
        manualHardReconnectPeripheralID = peripheral.identifier
        reconnectPeripheral = peripheral
        resetConnectionHandles()
        updateState(.failed(L10n.t("连接失败，请点击重试", "Connection failed. Tap to retry.")))
        connectLog(
            "temporary manual-only mode: waiting for user hard reconnect",
            detail: "source=\(source) id=\(peripheral.identifier.uuidString)"
        )
    }

    private func cancelManualHardReconnectState(reason: String) {
        failedGATTContext = nil
        failedGATTRetryGate.reset()
        let hadState = manualHardReconnectPeripheralID != nil
            || pendingManualHardReconnectPeripheralID != nil
            || isManualHardReconnectAttemptInProgress
            || manualHardReconnectLookupWorkItem != nil
            || manualHardReconnectReleaseTimeoutWorkItem != nil
            || manualHardReconnectCentralRebuildWorkItem != nil
            || manualHardReconnectOldCentral != nil
        let oldCentral = manualHardReconnectOldCentral
        let shouldRestoreOldCentralDelegate = manualHardReconnectCentralRebuildWorkItem != nil
            && oldCentral != nil
            && centralManager === oldCentral
        manualHardReconnectLookupWorkItem?.cancel()
        manualHardReconnectLookupWorkItem = nil
        manualHardReconnectReleaseTimeoutWorkItem?.cancel()
        manualHardReconnectReleaseTimeoutWorkItem = nil
        manualHardReconnectCentralRebuildWorkItem?.cancel()
        manualHardReconnectCentralRebuildWorkItem = nil
        manualHardReconnectLookupAttempt = 0
        pendingManualHardReconnectPeripheralID = nil
        isManualHardReconnectAttemptInProgress = false
        manualHardReconnectPeripheralID = nil
        manualHardReconnectOldPeripheral?.delegate = nil
        manualHardReconnectOldPeripheral = nil
        manualHardReconnectOldCentral = nil
        if shouldRestoreOldCentralDelegate, let oldCentral {
            oldCentral.delegate = self
            didRegisterConnectionEvents = false
            if oldCentral.state == .poweredOn {
                registerForSystemConnectionEventsIfNeeded()
            }
        }
        if hadState {
            connectLog("manual hard reconnect cancelled", detail: "reason=\(reason)")
        }
    }

    /// 仅「系统已连接 + 自动软恢复已耗尽」时可调用。
    /// 用户点击后先等旧连接释放，再创建无状态恢复标识的临时 central。
    @discardableResult
    func hardReconnectAfterUserTap(peripheralID: UUID) -> Bool {
        guard case .failed = connectionState,
              manualHardReconnectPeripheralID == peripheralID else {
            connectLog(
                "manual hard reconnect ignored: card is not retryable",
                detail: "id=\(peripheralID.uuidString) required=\(manualHardReconnectPeripheralID?.uuidString ?? "nil")"
            )
            return false
        }
        if boundBLEReconnectPolicy.isExhausted {
            boundBLEReconnectPolicy.reset()
            clearManualHardReconnectRequirement(reason: "user retry after automatic retry limit")
            return reconnectBoundDevice(boundSerialNumbers: [peripheralID.uuidString], reason: "user-retry-after-limit")
        }
        boundBLEReconnectPolicy.reset()
        guard let systemPeripheral = systemConnectedPeripheral(matching: peripheralID) else {
            clearManualHardReconnectRequirement(reason: "user tap but system transport disconnected")
            updateState(.disconnected)
            startSystemReconnectMonitor()
            return true
        }

        connectLog(
            "manual hard reconnect: begin old context release",
            detail: "id=\(peripheralID.uuidString)",
            direction: .sent
        )
        manualHardReconnectPeripheralID = nil
        pendingManualHardReconnectPeripheralID = peripheralID
        isManualHardReconnectAttemptInProgress = true
        manualHardReconnectLookupAttempt = 0
        userInitiatedDisconnect = false
        autoReconnectEnabled = true
        standingConnectAllowed = false
        standingConnectRecoveryCount = 0
        cancelAutomaticGATTRecovery(reason: "user requested hard reconnect", resetAttempts: true)
        stopSystemReconnectMonitor()
        cancelConnectWatchdog()
        cancelDiscoverServicesWorkItem()
        cancelScanTimeout()
        cancelProbeStart()
        manualReconnectScanWorkItem?.cancel()
        manualReconnectScanWorkItem = nil
        manualHardReconnectLookupWorkItem?.cancel()
        manualHardReconnectLookupWorkItem = nil

        let oldCentral = centralManager!
        let oldPeripheral = connectedPeripheral ?? reconnectPeripheral ?? systemPeripheral
        manualHardReconnectOldCentral = oldCentral
        manualHardReconnectOldPeripheral = oldPeripheral
        oldCentral.stopScan()
        oldPeripheral.delegate = nil
        standingConnectPeripheralID = nil
        reconnectPeripheral = nil
        resetConnectionHandles()
        updateState(.connecting)
        connectLog(
            "manual hard reconnect: waiting for old link release",
            detail: "id=\(peripheralID.uuidString) state=\(peripheralStateDescription(oldPeripheral.state)) timeout=\(manualHardReconnectReleaseTimeoutSeconds)s"
        )
        if oldPeripheral.state == .disconnected {
            completeManualHardReconnectOldContextRelease(
                central: oldCentral,
                peripheral: oldPeripheral,
                source: "already-disconnected"
            )
        } else {
            oldCentral.cancelPeripheralConnection(oldPeripheral)
            scheduleManualHardReconnectReleaseTimeout(
                central: oldCentral,
                peripheral: oldPeripheral
            )
        }
        return true
    }

    private func scheduleManualHardReconnectReleaseTimeout(
        central: CBCentralManager,
        peripheral: CBPeripheral
    ) {
        manualHardReconnectReleaseTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak central, weak peripheral] in
            guard let self, let central, let peripheral else { return }
            self.manualHardReconnectReleaseTimeoutWorkItem = nil
            self.completeManualHardReconnectOldContextRelease(
                central: central,
                peripheral: peripheral,
                source: "timeout"
            )
        }
        manualHardReconnectReleaseTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + manualHardReconnectReleaseTimeoutSeconds,
            execute: work
        )
    }

    private func isManualHardReconnectOldContext(
        central: CBCentralManager,
        peripheral: CBPeripheral
    ) -> Bool {
        guard isManualHardReconnectAttemptInProgress,
              let targetID = pendingManualHardReconnectPeripheralID,
              let oldCentral = manualHardReconnectOldCentral else { return false }
        return central === oldCentral && peripheral.identifier == targetID
    }

    @discardableResult
    private func consumeManualHardReconnectOldContextRelease(
        central: CBCentralManager,
        peripheral: CBPeripheral,
        source: String
    ) -> Bool {
        guard isManualHardReconnectOldContext(central: central, peripheral: peripheral) else {
            return false
        }
        completeManualHardReconnectOldContextRelease(
            central: central,
            peripheral: peripheral,
            source: source
        )
        return true
    }

    private func completeManualHardReconnectOldContextRelease(
        central: CBCentralManager,
        peripheral: CBPeripheral,
        source: String
    ) {
        guard isManualHardReconnectOldContext(central: central, peripheral: peripheral) else {
            return
        }
        manualHardReconnectReleaseTimeoutWorkItem?.cancel()
        manualHardReconnectReleaseTimeoutWorkItem = nil
        central.stopScan()
        if peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral.delegate = nil
        central.delegate = nil
        didRegisterConnectionEvents = false
        standingConnectPeripheralID = nil
        reconnectPeripheral = nil
        resetConnectionHandles()
        connectLog(
            "manual hard reconnect: old link released",
            detail: "source=\(source) id=\(peripheral.identifier.uuidString) state=\(peripheralStateDescription(peripheral.state))"
        )

        manualHardReconnectCentralRebuildWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak central] in
            guard let self, let central,
                  self.isManualHardReconnectAttemptInProgress,
                  self.pendingManualHardReconnectPeripheralID != nil,
                  self.centralManager === central,
                  self.manualHardReconnectOldCentral === central else { return }
            self.manualHardReconnectCentralRebuildWorkItem = nil
            self.manualHardReconnectOldPeripheral = nil
            self.manualHardReconnectOldCentral = nil
            self.connectLog(
                "manual hard reconnect: create ephemeral CBCentralManager",
                detail: "restoreIdentifier=none delay=\(self.manualHardReconnectCentralRebuildDelaySeconds)s",
                direction: .sent
            )
            self.centralManager = CBCentralManager(delegate: self, queue: nil, options: nil)
        }
        manualHardReconnectCentralRebuildWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + manualHardReconnectCentralRebuildDelaySeconds,
            execute: work
        )
    }

    private func resumeManualHardReconnectIfPossible() {
        guard isManualHardReconnectAttemptInProgress,
              let targetID = pendingManualHardReconnectPeripheralID,
              !isManualHardReconnectCentralTransitionInProgress,
              centralManager?.state == .poweredOn else { return }

        // 点击时已确认系统连接。新 manager 优先重新查询；查询窗口内允许使用
        // 刚刚的 peerConnected 证据取回新 CBPeripheral，peerDisconnected 会立即清掉该证据。
        guard let peripheral = systemConnectedPeripheral(matching: targetID) else {
            manualHardReconnectLookupAttempt += 1
            guard manualHardReconnectLookupAttempt <= maxManualHardReconnectLookupAttempts else {
                isManualHardReconnectAttemptInProgress = false
                pendingManualHardReconnectPeripheralID = nil
                manualHardReconnectLookupWorkItem = nil
                systemTransportConnectedPeripheralIDs.remove(targetID)
                updateState(.disconnected)
                startSystemReconnectMonitor()
                connectLog(
                    "manual hard reconnect stopped: system transport not connected",
                    detail: "id=\(targetID.uuidString)"
                )
                return
            }
            let work = DispatchWorkItem { [weak self] in
                self?.manualHardReconnectLookupWorkItem = nil
                self?.resumeManualHardReconnectIfPossible()
            }
            manualHardReconnectLookupWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + manualHardReconnectLookupIntervalSeconds,
                execute: work
            )
            return
        }

        manualHardReconnectLookupWorkItem?.cancel()
        manualHardReconnectLookupWorkItem = nil
        pendingManualHardReconnectPeripheralID = nil
        reconnectPeripheral = peripheral
        standingConnectAllowed = true
        connectLog(
            "manual hard reconnect: fresh central connect",
            detail: "id=\(targetID.uuidString) peripheralState=\(peripheralStateDescription(peripheral.state))",
            direction: .sent
        )
        if peripheral.state == .connected {
            attachToConnectedPeripheral(peripheral)
        } else {
            armSystemAutoConnect(peripheral, force: true, systemTransportObserved: true)
        }
    }

    /// 眼镜断电重连后，系统层已连但 App GATT 未就绪时，周期尝试接管。
    private func startSystemReconnectMonitor() {
        stopSystemReconnectMonitor()
        if stopBoundReconnectIfExhausted() { return }
        guard autoReconnectEnabled, !userInitiatedDisconnect else { return }
        guard manualHardReconnectPeripheralID == nil || failedGATTContext != nil else { return }
        if case .ready = connectionState { return }
        let work = DispatchWorkItem { [weak self] in
            self?.tickSystemReconnectMonitor()
        }
        systemReconnectMonitorWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func stopSystemReconnectMonitor() {
        systemReconnectMonitorWorkItem?.cancel()
        systemReconnectMonitorWorkItem = nil
    }

    private func scheduleNextSystemReconnectMonitor(after seconds: TimeInterval) {
        stopSystemReconnectMonitor()
        guard autoReconnectEnabled, !userInitiatedDisconnect else { return }
        guard manualHardReconnectPeripheralID == nil || failedGATTContext != nil else { return }
        if case .ready = connectionState { return }
        let work = DispatchWorkItem { [weak self] in
            self?.tickSystemReconnectMonitor()
        }
        systemReconnectMonitorWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func tickSystemReconnectMonitor() {
        systemReconnectMonitorWorkItem = nil
        if stopBoundReconnectIfExhausted() { return }
        guard autoReconnectEnabled, !userInitiatedDisconnect else { return }
        guard !isAutomaticGATTRecoveryInProgress else { return }
        if case .ready = connectionState { return }

        if case .failed = connectionState, manualHardReconnectPeripheralID != nil {
            _ = recoverFailedGATTIfPossible(source: "systemReconnectMonitor", allowRetry: true)
            scheduleNextSystemReconnectMonitor(after: 5)
            return
        }

        // GATT 发现进行中：不打断，稍后再看是否已 ready / 是否卡住需重 attach。
        if isGATTDiscoveryInProgress {
            scheduleNextSystemReconnectMonitor(after: 2.5)
            return
        }

        if attachToAlreadyConnectedPeripheralIfPossible(source: "systemReconnectMonitor") {
            connectLog("system reconnect monitor: handled bound target recovery")
            // attach 会进入 connecting；ready 后 updateState 停轮询。发现中再盯一眼。
            scheduleNextSystemReconnectMonitor(after: 3.0)
            return
        }

        // No cached target yet, or a bounded scan is cooling down. Keep monitoring.
        scheduleNextSystemReconnectMonitor(after: 2.5)
    }

    /// 系统层外设连接/断开事件（A2DP 先连上、App GATT 未就绪时的补救入口）。
    private func registerForSystemConnectionEventsIfNeeded() {
        guard let centralManager, !didRegisterConnectionEvents else { return }
        didRegisterConnectionEvents = true
        centralManager.registerForConnectionEvents(options: [
            CBConnectionEventMatchingOption.serviceUUIDs: Self.supportedServiceUUIDs
        ])
        print("\(logTag) registered for system connection events")
        connectLog(
            "registered for system connection events",
            detail: "serviceFilter=\(Self.supportedServiceUUIDs.map(\.uuidString).joined(separator: ",")) saved=\(savedPeripheralID()?.uuidString ?? "none"); registration_does_not_confirm_connection"
        )
    }

    /// 优先接管系统已连接外设，否则恢复已绑定目标。已处理返回 true。
    /// 只接管「已保存」那副眼镜，禁止系统已连的其它同型号眼镜抢身份。
    @discardableResult
    private func attachToAlreadyConnectedPeripheralIfPossible(source: String = "attach") -> Bool {
        if stopBoundReconnectIfExhausted() { return true }
        guard gen1OTAPeripheralID == nil else { return false }
        if isManualHardReconnectCentralTransitionInProgress {
            connectLog("attach deferred: rebuilding central")
            return true
        }
        guard centralManager?.state == .poweredOn else {
            logConnectionGateSnapshot(
                source: source, targetID: savedPeripheralID(), retrieved: [], cached: nil,
                decision: "wait_bluetooth_powered_on", queryPerformed: false
            )
            return false
        }
        if case .ready = connectionState { return true }
        if case .failed = connectionState, manualHardReconnectPeripheralID != nil {
            if recoverFailedGATTIfPossible(source: source, allowRetry: true) { return true }
            connectLog(
                "failed GATT rechecked: waiting for valid handles or retry cooldown",
                detail: "id=\(manualHardReconnectPeripheralID?.uuidString ?? "nil")"
            )
            return true
        }

        // 已在对该外设做 GATT 发现：不要重复 attach（会打断 discoverServices）
        if isGATTDiscoveryInProgress {
            connectLog(
                "attach skipped: GATT discovery already in progress",
                detail: "state=\(connectStateDescription(connectionState))"
            )
            return true
        }

        let savedID = savedPeripheralID()
        let systemConnected = centralManager.retrieveConnectedPeripherals(
            withServices: Self.supportedServiceUUIDs
        )
        systemTransportConnectedPeripheralIDs.formUnion(systemConnected.map(\.identifier))

        let cachedTarget = savedID.flatMap { centralManager.retrievePeripherals(withIdentifiers: [$0]).first }
        let heldTarget = (connectedPeripheral ?? reconnectPeripheral).flatMap {
            $0.identifier == savedID ? $0 : nil
        }
        let targetReturned = savedID.map { id in systemConnected.contains { $0.identifier == id } } ?? false
        let hasConnectedTarget = targetReturned || cachedTarget?.state == .connected || heldTarget?.state == .connected
        logConnectionGateSnapshot(
            source: source, targetID: savedID, retrieved: systemConnected,
            cached: heldTarget?.state == .connected ? heldTarget : cachedTarget,
            decision: savedID == nil ? "no_saved_target"
                : hasConnectedTarget ? "evaluate_system_connected_target"
                : "no_matching_system_peripheral; evaluate_bound_BLE_reconnect"
        )

        // 0) 当前持有的外设在系统层已是 connected，且必须是已保存目标
        if let peripheral = connectedPeripheral ?? reconnectPeripheral,
           peripheral.state == .connected {
            if let savedID, peripheral.identifier != savedID {
                connectLog(
                    "attach held peripheral ignored (not saved)",
                    detail: "held=\(peripheral.identifier.uuidString) saved=\(savedID.uuidString)"
                )
            } else {
                connectLog(
                    "attach held peripheral already connected",
                    detail: "id=\(peripheral.identifier.uuidString)"
                )
                attachToConnectedPeripheral(peripheral)
                return true
            }
        }

        // 1) 优先：已保存 UUID 且系统传输层已连接。
        // retrieveConnectedPeripherals 可能返回 state=disconnected：这表示系统/其它 profile
        // 已连，但本 CBCentralManager 还没认领 GATT。此时挂起 connect 等 didConnect，不走短看门狗反复取消。
        if let savedID {
            if let peripheral = systemConnected.first(where: { $0.identifier == savedID }) {
                if peripheral.state == .connected {
                    connectLog("attach saved system-connected peripheral", detail: "id=\(savedID.uuidString)")
                    attachToConnectedPeripheral(peripheral)
                } else {
                    connectLog(
                        "system transport connected; arm saved GATT peripheral",
                        detail: "id=\(savedID.uuidString) peripheralState=\(peripheralStateDescription(peripheral.state))"
                    )
                    userInitiatedDisconnect = false
                    autoReconnectEnabled = true
                    standingConnectAllowed = true
                    armSystemAutoConnect(
                        peripheral,
                        force: true,
                        systemTransportObserved: true
                    )
                }
                return true
            }
            if let peripheral = cachedTarget,
               peripheral.state == .connected {
                connectLog("attach saved peripheral already connected", detail: "id=\(savedID.uuidString)")
                attachToConnectedPeripheral(peripheral)
                return true
            }
            if !systemConnected.isEmpty {
                let others = systemConnected.map(\.identifier.uuidString).joined(separator: ",")
                connectLog(
                    "attach skipped: other glasses connected",
                    detail: "others=\(others) saved=\(savedID.uuidString)"
                )
            }
            return reconnectSavedPeripheralWithoutSystemConnection(source: source)
        }

        // 2) 无已保存设备（首次/已清会话）：不自动接管任意眼镜
        if !systemConnected.isEmpty {
            connectLog(
                "attach skipped: no saved peripheral",
                detail: "ignore system-connected count=\(systemConnected.count)"
            )
        }
        return false
    }

    private func recordBoundBLEAttemptFailure() {
        guard !boundBLEAttemptFailureCounted else { return }
        boundBLEAttemptFailureCounted = true
        boundBLEReconnectPolicy.noteConnectionFailure(now: ProcessInfo.processInfo.systemUptime)
    }

    /// Stop after three total automatic attempts; wait for a new system event.
    @discardableResult
    private func stopBoundReconnectIfExhausted() -> Bool {
        guard boundBLEReconnectPolicy.isExhausted, let id = savedPeripheralID() else { return false }
        if case .failed = connectionState, manualHardReconnectPeripheralID == id { return true }
        stopSystemReconnectMonitor()
        stopBatteryPolling()
        if boundReconnectScanTargetID != nil { stopScan() }
        cancelAutomaticGATTRecovery(reason: "automatic BLE retry limit", resetAttempts: false)
        cancelConnectWatchdog()
        cancelDiscoverServicesWorkItem()
        let peripheral = connectedPeripheral ?? reconnectPeripheral
        boundBLEStopWaitingForRelease = peripheral.map { $0.state != .disconnected } ?? false
        reconnectPeripheral = peripheral
        standingConnectPeripheralID = nil
        standingConnectAllowed = false
        manualHardReconnectPeripheralID = id
        resetConnectionHandles()
        updateState(.failed(L10n.t("自动连接已尝试 3 次，等待眼镜重新连接蓝牙，或点击重试", "Automatic connection attempted 3 times. Waiting for glasses Bluetooth, or tap to retry.")))
        connectLog("automatic BLE retry limit reached", detail: "failedAttempts=\(boundBLEReconnectPolicy.failedAttempts) maxAttempts=\(BoundBLEReconnectPolicy.maxAttempts) id=\(id.uuidString); polling_stopped waiting_for_new_system_event")
        if let peripheral, peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        return true
    }

    /// Reconnect only the saved UUID. Never adopt another nearby device by name.
    @discardableResult
    private func reconnectSavedPeripheralWithoutSystemConnection(source: String) -> Bool {
        guard autoReconnectEnabled, !userInitiatedDisconnect,
              centralManager?.state == .poweredOn,
              gen1OTAPeripheralID == nil, !isRestoringGen1OTAConnection,
              !isPairingSessionActive, !isManualPairingScan, !isManualReconnectScan,
              !isManualReconnectConnect, !isProbingService,
              !isAutomaticGATTRecoveryInProgress,
              !isManualHardReconnectAttemptInProgress,
              !isManualHardReconnectCentralTransitionInProgress,
              manualHardReconnectPeripheralID == nil,
              let id = savedPeripheralID() else { return false }
        guard boundBLEReconnectPolicy.canRetry(now: ProcessInfo.processInfo.systemUptime) else { return false }
        if boundReconnectScanTargetID == id { return true }
        let cached = centralManager.retrievePeripherals(withIdentifiers: [id]).first
            ?? reconnectPeripheral.flatMap({ $0.identifier == id ? $0 : nil })
        if let peripheral = cached {
            // Wait for release callbacks before issuing a new connection request.
            if peripheral.state == .disconnecting {
                startSystemReconnectMonitor()
                return true
            }
            if !boundBLEReconnectPolicy.requiresRediscovery {
                connectLog("reconnect saved BLE without system connection", detail: "source=\(source) id=\(id.uuidString)")
                standingConnectAllowed = true
                armSystemAutoConnect(peripheral, force: true)
                return true
            }
        }
        guard !centralManager.isScanning,
              boundBLEReconnectPolicy.claimScan(now: ProcessInfo.processInfo.systemUptime) else { return false }
        boundReconnectScanTargetID = id
        hasStartedConnect = false
        updateState(.scanning)
        connectLog("bound BLE reconnect scan started", detail: "source=\(source) id=\(id.uuidString); exact UUID only")
        // Some firmware omits service UUIDs in advertisements. Match identity in didDiscover.
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.boundReconnectScanTargetID == id else { return }
            self.stopScan()
            guard self.autoReconnectEnabled, !self.userInitiatedDisconnect,
                  self.savedPeripheralID() == id else { return }
            self.updateState(.disconnected)
            self.boundBLEReconnectPolicy.noteConnectionFailure(now: ProcessInfo.processInfo.systemUptime)
            self.connectLog("bound BLE reconnect scan timed out", detail: "id=\(id.uuidString); retry after cooldown")
            self.startSystemReconnectMonitor()
        }
        boundReconnectScanTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + manualReconnectScanTimeoutSeconds, execute: work)
        return true
    }

    private var isGATTDiscoveryInProgress: Bool {
        guard let peripheral = connectedPeripheral, peripheral.state == .connected else { return false }
        switch connectionState {
        case .connecting, .discoveringServices, .enablingNotifications:
            return true
        default:
            return false
        }
    }

    /// 系统层已连接时：先 connect() 认领连接，再发现服务。
    /// 仅 discoverServices 而不 connect，iOS 往往不会回调 didDiscoverServices。
    private func attachToConnectedPeripheral(_ peripheral: CBPeripheral) {
        if stopBoundReconnectIfExhausted() { return }
        guard !isAutomaticGATTRecoveryInProgress else {
            connectLog(
                "attach deferred: GATT recovery in progress",
                detail: "id=\(peripheral.identifier.uuidString)"
            )
            return
        }
        if boundReconnectScanTargetID != nil { stopScan() }
        if shouldRequireTemporaryManualHardReconnect(for: peripheral) {
            systemTransportConnectedPeripheralIDs.insert(peripheral.identifier)
            requireTemporaryManualHardReconnect(
                for: peripheral,
                source: "attachToConnectedPeripheral"
            )
            return
        }
        // 同一外设已在连接/发现/就绪流程中，避免 homeAppear / userInfoLoaded 重复 connect()
        // （重复 connect 会产生多次 didConnect，并可能打断 iOS 的 MTU 协商）。
        if connectedPeripheral?.identifier == peripheral.identifier {
            switch connectionState {
            case .connecting, .discoveringServices, .enablingNotifications, .ready:
                connectLog(
                    "attachToConnectedPeripheral ignored",
                    detail: "state=\(connectStateDescription(connectionState)) id=\(peripheral.identifier.uuidString)"
                )
                return
            default:
                break
            }
        }

        if identityPeripheralID != peripheral.identifier {
            clearLiveDeviceIdentity(reason: "attach different peripheral")
        }

        cancelDiscoverServicesWorkItem()
        userInitiatedDisconnect = false
        autoReconnectEnabled = true
        boundBLEAttemptFailureCounted = false
        isBatteryRefreshMode = true
        reconnectPeripheral = peripheral
        connectedPeripheral = peripheral
        peripheral.delegate = self
        hasStartedConnect = true
        isServiceDiscovered = false
        isNotificationEnabled = false
        writeCharacteristic = nil
        notifyCharacteristic = nil
        gattDiscoveryAttempt = 0
        savePeripheralID(peripheral.identifier)

        connectLog(
            "attachToConnectedPeripheral",
            detail: "id=\(peripheral.identifier.uuidString) peripheralState=\(peripheralStateDescription(peripheral.state)) services=\(peripheral.services?.count ?? -1)",
            direction: .sent
        )

        if let services = peripheral.services, !services.isEmpty {
            startConnectWatchdog(for: peripheral)
            recoverCharacteristics(from: peripheral)
            return
        }

        // Apple 要求：retrieveConnectedPeripherals 拿到的设备仍需 connect，App 才能收 GATT 回调。
        // 已连接时 didConnect 通常会立刻回调；若没有，由 backup / watchdog 补 discoverServices。
        updateState(.connecting)
        connectLog("claim system connection via connect()", detail: "id=\(peripheral.identifier.uuidString)", direction: .sent)
        centralManager.connect(peripheral, options: nil)

        if peripheral.state == .connected {
            scheduleDiscoverServices(on: peripheral, delay: 0.25, reason: "post-claim")
        }
        startConnectWatchdog(for: peripheral)
    }

    private func cancelDiscoverServicesWorkItem() {
        discoverServicesWorkItem?.cancel()
        discoverServicesWorkItem = nil
    }

    /// 在已连接外设上发起 / 重试服务发现。
    private func scheduleDiscoverServices(on peripheral: CBPeripheral, delay: TimeInterval, reason: String) {
        cancelDiscoverServicesWorkItem()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.beginDiscoverServices(on: peripheral, reason: reason)
        }
        discoverServicesWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginDiscoverServices(on peripheral: CBPeripheral, reason: String) {
        cancelDiscoverServicesWorkItem()
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        if case .ready = connectionState { return }
        if isServiceDiscovered { return }

        pendingCharacteristicServices.removeAll()
        pendingCharacteristicDiscoveries = 0
        gattDiscoveryAttempt += 1
        peripheral.delegate = self
        updateState(.discoveringServices)
        connectLog(
            "discoverServices",
            detail: "reason=\(reason) attempt=\(gattDiscoveryAttempt) peripheralState=\(peripheralStateDescription(peripheral.state)) requestedServiceUUIDs=all"
        )
        peripheral.discoverServices(nil)
        startConnectWatchdog(for: peripheral)
    }

    /// 从已连接外设恢复写/通知特征并读电量。
    private func recoverCharacteristics(from peripheral: CBPeripheral) {
        logProtocolServiceEvidence(peripheral, error: nil, source: "cached-services-before-recovery")
        let services = peripheral.services ?? []
        assignCharacteristics(from: services)
        if writeCharacteristic != nil, notifyCharacteristic != nil,
           deviceGeneration != .gen1G5K61 || gen1VoiceCharacteristic != nil {
            isServiceDiscovered = true
            isProtocolNotificationEnabled = protocolNotificationsReady
            isNotificationEnabled = isProtocolNotificationEnabled
            if protocolNotificationsReady {
                handleRecoveredReady(preferBatteryOnly: isDeviceInfoReady)
            } else {
                beginNotificationSetup(on: peripheral)
            }
        } else if let service = services.first(where: { Self.supportedServiceUUIDs.contains($0.uuid) }) {
            updateState(.discoveringServices)
            pendingCharacteristicDiscoveries = 1
            pendingCharacteristicServices = [service]
            peripheral.discoverCharacteristics(nil, for: service)
            startConnectWatchdog(for: peripheral)
        } else {
            updateState(.discoveringServices)
            peripheral.discoverServices(nil)
            startConnectWatchdog(for: peripheral)
        }
    }

    /// recoverCharacteristics 直接进 ready 时补刷身份，避免跳过 getdevinfo。
    private func handleRecoveredReady(preferBatteryOnly: Bool) {
        prepareBatteryForFreshRead()
        updateState(.ready)
        identityPeripheralID = connectedPeripheral?.identifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.isBatteryRefreshMode = false
            // getdevstat 由 updateState(.ready) 统一调度，这里不再重复发。
            if preferBatteryOnly, self.isDeviceInfoReady {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.scheduleRoutineDeviceRefresh()
                }
            } else {
                self.statusMessage = L10n.t("正在读取设备信息...", "Reading device info...")
                self.queryInitialDeviceInfo()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.markDeviceInfoReadyIfNeeded(force: true)
                }
            }
        }
    }

    /// 由 AiVisionTransferManager 在识图开始/结束时调用。
    func setAIVisionTransferBusy(_ busy: Bool) {
        let wasBusy = isAIVisionTransferBusy
        guard wasBusy != busy else { return }
        isAIVisionTransferBusy = busy
        print("\(logTag) aiVisionTransferBusy=\(busy)")
        if wasBusy, !busy {
            finishRuntimeOperationIfNeeded(
                expected: .aiVisionOperating,
                fallback: .unknown,
                reason: "ai-vision-finished"
            )
            // 识图结束：补刷电量与待导入（此前被挡的查询）。
            scheduleRoutineDeviceRefresh()
        }
    }

    private var shouldDeferGen1BackgroundQueries: Bool {
        deviceGeneration == .gen1G5K61 && (
            isHomeVideoStartInProgress || isVideoRecording || isVideoStopping
                || homeVideoCapture.startedAt != nil || isAIRecording
                || (!isDeviceRuntimeIdle && deviceRuntimeStatus != .photoTaking) || gen1APImportIdentity != nil
                || connectedPeripheral.map { gen1HotspotCleanup.isPending($0.identifier) } == true
        )
    }

    private func scheduleDeferredRoutineRetry(after seconds: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, seconds)
        if let existing = deferredRoutineRetryAt, existing <= deadline { return }
        deferredRoutineRetryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredRoutineRetryAt = nil
            self.deferredRoutineRetryWorkItem = nil
            self.runDeferredRoutineQueriesIfNeeded()
        }
        deferredRoutineRetryAt = deadline
        deferredRoutineRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, seconds), execute: work)
    }

    private func deferGen1QueryIfNeeded(_ query: Gen1BackgroundQueryGate.Query) -> Bool {
        guard deviceGeneration == .gen1G5K61 else { return false }
        // Photo completion can depend on the fresh file list when firmware omits
        // its idle notification. Do not suppress that existing completion path.
        let blocked = shouldDeferGen1BackgroundQueries || (query == .battery && isTakingPhoto)
        let delay = gen1BackgroundQueryGate.delay(
            for: query, at: ProcessInfo.processInfo.systemUptime,
            freshContent: query == .fileList && needsFreshGen1FileList
        )
        guard blocked || delay > 0 else { return false }
        if query == .battery { deferredBatteryQuery = true }
        else { deferredPendingImportQuery = true }
        DebugLogStore.logBLEEvent("Gen1 background query deferred", detail: "query=\(query) busy=\(blocked) delay=\(delay) runtime=\(deviceRuntimeStatus.name) recording=\(isVideoRecording) pendingWrites=\(pendingBLEWrites.count)")
        if !blocked { scheduleDeferredRoutineRetry(after: delay) }
        return true
    }

    func queryBatteryOnly() {
        guard isReady else { return }
        if deferGen1QueryIfNeeded(.battery) { return }
        if isFirmwareUpgradeFlowBusy {
            deferredBatteryQuery = true
            print("\(logTag) queryBatteryOnly deferred: firmware upgrade busy")
            return
        }
        if isAIVisionTransferBusy {
            deferredBatteryQuery = true
            print("\(logTag) queryBatteryOnly deferred: AI vision transfer busy")
            return
        }
        if isSerialGetDevInfoInProgress {
            deferredBatteryQuery = true
            print("\(logTag) queryBatteryOnly deferred: serial getdevinfo in progress")
            return
        }
        let ok = sendCommand(AstraA1BleProtocol.buildGetDevInfoCommand(type: .battery))
        print("\(logTag) queryBatteryOnly sent=\(ok)")
    }

    private func scheduleRoutineDeviceRefresh() {
        if isFirmwareUpgradeFlowBusy {
            deferredBatteryQuery = true
            deferredPendingImportQuery = true
            print("\(logTag) routine refresh deferred: firmware upgrade busy")
            return
        }
        if isAIVisionTransferBusy {
            deferredBatteryQuery = true
            deferredPendingImportQuery = true
            print("\(logTag) routine refresh deferred: AI vision transfer busy")
            return
        }
        if isSerialGetDevInfoInProgress {
            deferredBatteryQuery = true
            deferredPendingImportQuery = true
            print("\(logTag) routine refresh deferred: serial getdevinfo in progress")
            return
        }
        // 首页 onAppear + userInfoLoaded 常连续触发，合并成一次。
        routineRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isFirmwareUpgradeFlowBusy || self.isAIVisionTransferBusy || self.isSerialGetDevInfoInProgress {
                self.deferredBatteryQuery = true
                self.deferredPendingImportQuery = true
                print("\(self.logTag) routine refresh deferred after debounce")
                return
            }
            self.queryBatteryOnly()
            self.queryPendingImportFiles()
        }
        routineRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// 连上/接管 GATT 后等待新读数期间，沿用同一副眼镜上次的非 0 电量，等 batt0 或 batteryntf 覆盖。
    private func prepareBatteryForFreshRead() {
        guard let last = lastKnownBatteryPercent, last > 0,
              lastKnownBatteryPeripheralID == connectedPeripheral?.identifier else {
            clearBatteryDisplay()
            return
        }
        deviceBattery = "\(last)"
        isBatteryLevelKnown = true
    }

    /// 仅清展示值，保留 lastKnown 供同一副眼镜重连后回填。
    private func clearBatteryDisplay() {
        deviceBattery = nil
        isBatteryLevelKnown = false
    }

    private func resetBatteryDisplayForFreshRead() {
        lastKnownBatteryPercent = nil
        lastKnownBatteryPeripheralID = nil
        clearBatteryDisplay()
    }

    /// 对齐安卓 DevicePagerAdapter.mergeDeviceInfo：读到 0 时若已有非 0 读数则保留旧值，
    /// 固件在忙（传输/录音）时会回 0，直接覆盖会让首页反复跳 0%。
    private func applyBatteryPercent(_ percent: Int, source: String) {
        let clamped = max(0, min(100, percent))
        // Only Gen2 reports charging through chargestat. Battery values carry no charging state.
        let charging = deviceGeneration == .gen2 && deviceIsCharging
        if clamped == 0, let last = lastKnownBatteryPercent, last > 0 {
            deviceIsCharging = charging
            print("\(logTag) battery \(source)=0 ignored, keep last=\(last)%")
            return
        }
        if clamped > 0 {
            lastKnownBatteryPercent = clamped
            lastKnownBatteryPeripheralID = connectedPeripheral?.identifier
        }
        deviceBattery = "\(clamped)"
        deviceIsCharging = charging
        isBatteryLevelKnown = true
        print("\(logTag) battery updated source=\(source) level=\(clamped)% charging=\(charging)")
    }

    /// 连上后周期性主动查询电量（安卓 startBatteryPolling 等价实现）。
    private func startBatteryPolling() {
        stopBatteryPolling()
        scheduleNextBatteryPoll(after: 2)
    }

    private func stopBatteryPolling() {
        batteryPollingWorkItem?.cancel()
        batteryPollingWorkItem = nil
    }

    private func scheduleNextBatteryPoll(after seconds: TimeInterval) {
        batteryPollingWorkItem?.cancel()
        guard case .ready = connectionState else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.tickBatteryPolling()
        }
        batteryPollingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func tickBatteryPolling() {
        batteryPollingWorkItem = nil
        guard case .ready = connectionState else { return }
        if isFirmwareUpgradeFlowBusy {
            deferredBatteryQuery = true
            print("\(logTag) battery poll deferred: firmware upgrade busy")
            return
        }
        queryBatteryOnly()
        let next = isBatteryLevelKnown ? batteryPollingInterval : batteryPollingRetryInterval
        scheduleNextBatteryPoll(after: next)
    }

    private func runDeferredBatteryQueryIfNeeded() {
        guard deferredBatteryQuery else { return }
        deferredBatteryQuery = false
        queryBatteryOnly()
    }

    private func runDeferredRoutineQueriesIfNeeded() {
        guard isReady, !isFirmwareUpgradeFlowBusy, !shouldDeferGen1BackgroundQueries else { return }
        runDeferredBatteryQueryIfNeeded()
        guard deferredPendingImportQuery else { return }
        deferredPendingImportQuery = false
        queryPendingImportFiles()
    }

    /// 查询眼镜端待导入媒体文件数量。
    func queryPendingImportFiles() {
        guard isReady else {
            print("\(logTag) queryPendingImportFiles skipped: not ready")
            return
        }
        if deferGen1QueryIfNeeded(.fileList) { return }
        if isFirmwareUpgradeFlowBusy {
            deferredPendingImportQuery = true
            print("\(logTag) queryPendingImportFiles deferred: firmware upgrade busy")
            return
        }
        if isAIVisionTransferBusy {
            deferredPendingImportQuery = true
            print("\(logTag) queryPendingImportFiles deferred: AI vision transfer busy")
            return
        }
        if isSerialGetDevInfoInProgress {
            deferredPendingImportQuery = true
            print("\(logTag) queryPendingImportFiles deferred: serial getdevinfo in progress")
            return
        }
        let ok = sendCommand(AstraA1BleProtocol.buildHasNewFileCommand())
        print("\(logTag) queryPendingImportFiles sent=\(ok)")
    }

    /// 文件删除已确认后立即扣减待导入数量，后续设备回包可更新真实剩余数量。
    func noteImportedMediaFiles(count: Int) {
        guard count > 0 else { return }
        let before = pendingImportFileCount
        pendingImportFileCount = max(0, pendingImportFileCount - count)
        print("\(logTag) noteImportedMediaFiles -\(count) pending \(before) -> \(pendingImportFileCount)")
    }

    /// A validated HTTP directory is authoritative when the BLE count is stale.
    func noteEmptyMediaDirectory() {
        pendingImportFileCount = 0
        print("\(logTag) pending media cleared: HTTP directory contains no media files")
    }

    /// 升级检测：优先等初连 getdevinfo 队列结束；仍缺则串行补查。
    func queryUpgradeDeviceInfo() {
        guard case .ready = connectionState, let peripheral = connectedPeripheral,
              !isFirmwareUpgradeFlowBusy, !isAIVisionTransferBusy else { return }
        let needSN = (deviceSN ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needBle = (deviceVersion2800 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needFw = (deviceVersion6350 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard needSN || needBle || needFw else {
            print("\(logTag) queryUpgradeDeviceInfo skipped: versions already present")
            return
        }
        if isSerialGetDevInfoInProgress {
            print("\(logTag) queryUpgradeDeviceInfo deferred: getdevinfo in progress")
            return
        }
        // Query completion also refreshes the UI. Reserve one fill-in per connection
        // so missing/truncated replies cannot start an endless loading/retry loop.
        guard let token = deviceVersionQueryGate.reserveAutomaticQuery() else { return }
        // 初连队列结束后再给回包留 2 秒；查询进行中时已在上方返回，避免叠发。
        print("\(logTag) queryUpgradeDeviceInfo will retry fill-in after 2.0s if still missing")
        let generation = initialDeviceInfoQueryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            defer { self.deviceVersionQueryGate.cancelPendingQuery(token) }
            guard case .ready = self.connectionState,
                  self.connectedPeripheral === peripheral,
                  !self.isFirmwareUpgradeFlowBusy, !self.isAIVisionTransferBusy else { return }
            guard self.initialDeviceInfoQueryGeneration == generation else {
                print("\(self.logTag) queryUpgradeDeviceInfo fill-in skipped: connection/query generation changed")
                return
            }
            let stillNeedSN = (self.deviceSN ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let stillNeedBle = (self.deviceVersion2800 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let stillNeedFw = (self.deviceVersion6350 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard stillNeedSN || stillNeedBle || stillNeedFw else {
                print("\(self.logTag) queryUpgradeDeviceInfo fill-in skipped: versions arrived")
                return
            }
            guard !self.isSerialGetDevInfoInProgress else {
                print("\(self.logTag) queryUpgradeDeviceInfo fill-in deferred: getdevinfo in progress")
                return
            }
            guard self.deviceVersionQueryGate.claimAutomaticQuery(token) else { return }
            self.refreshDeviceVersionsAndStorage(includeSerialNumber: stillNeedSN, clearExisting: false)
        }
    }

    /// 关于设备页：逐项串行拉取名称、型号、SN、存储、蓝牙/固件版本等。
    func queryAboutDeviceInfo() {
        guard !isFirmwareUpgradeFlowBusy else {
            print("\(logTag) queryAboutDeviceInfo skipped: firmware upgrade busy")
            return
        }
        guard case .ready = connectionState else {
            ensureConnected(reason: "aboutDevice")
            return
        }
        deviceVersionQueryGate.cancelPendingQuery()
        cancelVersionsAndStorageQuery()
        cancelAboutDeviceInfoQuery()
        // 不先清空版本：查失败时仍可显示上次成功值（安卓 DeviceInfo 也是字段级覆盖）。
        isQueryingAboutDeviceInfo = true
        aboutDeviceInfoPendingTypes = [
            .name, .model, .sn, .storage, .version2800, .version6350
        ]
        print("\(logTag) queryAboutDeviceInfo start serial count=\(aboutDeviceInfoPendingTypes.count)")
        sendNextAboutDeviceInfoQuery()
    }

    /// 进入升级页等：串行 getdevinfo 拉存储、蓝牙/固件版本。
    /// - Parameter clearExisting: true 时先清空再查（强制刷新）；false 保留旧值直到新包覆盖。
    func refreshDeviceVersionsAndStorage(includeSerialNumber: Bool = false, clearExisting: Bool = true) {
        guard !isFirmwareUpgradeFlowBusy else {
            print("\(logTag) refreshDeviceVersionsAndStorage skipped: firmware upgrade busy")
            return
        }
        guard case .ready = connectionState else {
            ensureConnected(reason: "refreshVersionsAndStorage")
            return
        }
        // Explicit page refreshes remain available after a failure, but their
        // completion must not authorize another automatic query in this session.
        deviceVersionQueryGate.beginExplicitQuery()
        deviceVersionQueryFailed = false
        cancelAboutDeviceInfoQuery()
        isQueryingAboutDeviceInfo = false
        cancelVersionsAndStorageQuery()
        if clearExisting {
            invalidateDeviceVersionsAndStorageCache()
        }

        isQueryingDeviceVersionsAndStorage = true
        var types: [AstraA1BleProtocol.DevInfoType] = []
        if includeSerialNumber {
            types.append(.sn)
        }
        types.append(contentsOf: [.storage, .version2800, .version6350])
        versionsStoragePendingTypes = types
        print("\(logTag) refreshDeviceVersionsAndStorage start count=\(types.count) includeSN=\(includeSerialNumber) clear=\(clearExisting)")
        sendNextVersionsAndStorageQuery()
    }

    private func invalidateDeviceVersionsAndStorageCache() {
        deviceStorage = nil
        deviceVersion2800 = nil
        deviceVersion6350 = nil
        settingsVideoResolutionProfile = nil
        settingsWearDetectionEnabled = nil
        aiVoiceListeningDurationResponse = nil
        voiceWakeupResponse = nil
        factoryResetResult = nil
    }

    private func cancelVersionsAndStorageQuery() {
        versionsStorageQueryTimeout?.cancel()
        versionsStorageQueryTimeout = nil
        versionsStoragePendingTypes = []
        isQueryingDeviceVersionsAndStorage = false
    }

    private func cachedValue(for type: AstraA1BleProtocol.DevInfoType) -> String? {
        let raw: String?
        switch type {
        case .sn: raw = deviceSN
        case .storage: raw = deviceStorage
        case .version2800: raw = deviceVersion2800
        case .version6350: raw = deviceVersion6350
        case .name: raw = deviceName
        case .model: raw = deviceModel
        case .battery: raw = deviceBattery
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sendNextVersionsAndStorageQuery() {
        guard isQueryingDeviceVersionsAndStorage else { return }
        // 初连也在发送 getdevinfo，等待其结束后再推进页面刷新，保持Gen2发送间隔。
        guard !isInitialDeviceInfoQueryInProgress else { return }
        // 已有值的项跳过（补缺查询时避免重复打通道）。
        while let type = versionsStoragePendingTypes.first, cachedValue(for: type) != nil {
            print("\(logTag) refreshDeviceVersionsAndStorage skip cached type=0x\(String(format: "%02X", type.rawValue))")
            versionsStoragePendingTypes.removeFirst()
        }
        guard let type = versionsStoragePendingTypes.first else {
            completeVersionsAndStorageQuery()
            return
        }
        notifyReadAttempts = 0
        let sent = sendCommand(AstraA1BleProtocol.buildGetDevInfoCommand(type: type))
        print("\(logTag) refreshDeviceVersionsAndStorage type=0x\(String(format: "%02X", type.rawValue)) sent=\(sent)")
        armVersionsAndStorageTimeout(for: type)
    }

    private func armVersionsAndStorageTimeout(for type: AstraA1BleProtocol.DevInfoType) {
        guard !isInitialDeviceInfoQueryInProgress else { return }
        versionsStorageQueryTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isQueryingDeviceVersionsAndStorage else { return }
            // 截断后正在 read 完整包：再等一轮，勿直接跳过 ver28/ver63。
            if self.notifyReadInFlight {
                print("\(self.logTag) refreshDeviceVersionsAndStorage type=0x\(String(format: "%02X", type.rawValue)) timeout deferred (notify read in flight)")
                self.armVersionsAndStorageTimeout(for: type)
                return
            }
            print("\(self.logTag) refreshDeviceVersionsAndStorage type=0x\(String(format: "%02X", type.rawValue)) timeout")
            self.finishVersionsAndStorageQueryStep()
        }
        versionsStorageQueryTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutForVersionsAndStorageQuery(type), execute: work)
    }

    private func timeoutForVersionsAndStorageQuery(_ type: AstraA1BleProtocol.DevInfoType) -> TimeInterval {
        // ver28 字符串长，notify 常截断再 read，2.5s 不够。
        switch type {
        case .version2800, .version6350, .storage: return 5.0
        default: return versionsStorageQueryTimeoutSeconds
        }
    }

    private func finishVersionsAndStorageQueryStep() {
        // 初连回包可更新缓存，但不能推进尚未发送的页面查询或启动其超时。
        guard !isInitialDeviceInfoQueryInProgress else { return }
        versionsStorageQueryTimeout?.cancel()
        versionsStorageQueryTimeout = nil
        notifyReadAttempts = 0
        if !versionsStoragePendingTypes.isEmpty {
            versionsStoragePendingTypes.removeFirst()
        }
        if versionsStoragePendingTypes.isEmpty {
            completeVersionsAndStorageQuery()
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.sendNextVersionsAndStorageQuery()
            }
            versionsStorageQueryTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + getDevInfoSendIntervalSeconds, execute: work)
        }
    }

    private func completeVersionsAndStorageQuery() {
        deviceVersionQueryFailed = cachedValue(for: .version2800) == nil
            || cachedValue(for: .version6350) == nil
        isQueryingDeviceVersionsAndStorage = false
        DebugLogStore.logBLEEvent(
            "device version query completed",
            detail: "failed=\(deviceVersionQueryFailed) ver28=\(deviceVersion2800 ?? "nil") ver63=\(deviceVersion6350 ?? "nil") automaticRetry=false; reconnect or explicitly retry if incomplete"
        )
        runDeferredRoutineQueriesIfNeeded()
    }

    private func cancelAboutDeviceInfoQuery() {
        aboutDeviceInfoQueryTimeout?.cancel()
        aboutDeviceInfoQueryTimeout = nil
        aboutDeviceInfoPendingTypes = []
    }

    private func sendNextAboutDeviceInfoQuery() {
        guard isQueryingAboutDeviceInfo else { return }
        guard !isInitialDeviceInfoQueryInProgress else { return }
        // 关于页：名称/型号/SN 可跳过已有；版本与存储始终重查。
        while let type = aboutDeviceInfoPendingTypes.first {
            let skippable: Bool = {
                switch type {
                case .name, .model, .sn: return cachedValue(for: type) != nil
                default: return false
                }
            }()
            if skippable {
                print("\(logTag) queryAboutDeviceInfo skip cached type=0x\(String(format: "%02X", type.rawValue))")
                aboutDeviceInfoPendingTypes.removeFirst()
                continue
            }
            break
        }
        guard let type = aboutDeviceInfoPendingTypes.first else {
            isQueryingAboutDeviceInfo = false
            print("\(logTag) queryAboutDeviceInfo finished")
            runDeferredRoutineQueriesIfNeeded()
            return
        }
        notifyReadAttempts = 0
        let sent = sendCommand(AstraA1BleProtocol.buildGetDevInfoCommand(type: type))
        print("\(logTag) queryAboutDeviceInfo type=0x\(String(format: "%02X", type.rawValue)) sent=\(sent)")
        armAboutDeviceInfoTimeout(for: type)
    }

    private func armAboutDeviceInfoTimeout(for type: AstraA1BleProtocol.DevInfoType) {
        guard !isInitialDeviceInfoQueryInProgress else { return }
        aboutDeviceInfoQueryTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isQueryingAboutDeviceInfo else { return }
            if self.notifyReadInFlight {
                print("\(self.logTag) queryAboutDeviceInfo type=0x\(String(format: "%02X", type.rawValue)) timeout deferred (notify read in flight)")
                self.armAboutDeviceInfoTimeout(for: type)
                return
            }
            print("\(self.logTag) queryAboutDeviceInfo type=0x\(String(format: "%02X", type.rawValue)) timeout")
            self.finishAboutDeviceInfoQueryStep()
        }
        aboutDeviceInfoQueryTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutForAboutDeviceInfoQuery(type), execute: work)
    }

    private func timeoutForAboutDeviceInfoQuery(_ type: AstraA1BleProtocol.DevInfoType) -> TimeInterval {
        switch type {
        case .storage, .version2800, .version6350: return 5.0
        default: return aboutDeviceInfoQueryTimeoutSeconds
        }
    }

    private func finishAboutDeviceInfoQueryStep() {
        guard !isInitialDeviceInfoQueryInProgress else { return }
        aboutDeviceInfoQueryTimeout?.cancel()
        aboutDeviceInfoQueryTimeout = nil
        notifyReadAttempts = 0
        if !aboutDeviceInfoPendingTypes.isEmpty {
            aboutDeviceInfoPendingTypes.removeFirst()
        }
        if aboutDeviceInfoPendingTypes.isEmpty {
            isQueryingAboutDeviceInfo = false
            print("\(logTag) queryAboutDeviceInfo finished ver28=\(deviceVersion2800 ?? "nil") ver63=\(deviceVersion6350 ?? "nil")")
            runDeferredRoutineQueriesIfNeeded()
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.sendNextAboutDeviceInfoQuery()
            }
            aboutDeviceInfoQueryTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + getDevInfoSendIntervalSeconds, execute: work)
        }
    }

    var deviceStorageDisplay: String {
        guard let deviceStorage else { return "—" }
        return AstraA1BleProtocol.formatStorageDisplay(deviceStorage)
    }

    /// iOS 不向第三方 App 暴露 BLE MAC，仅连接时可用外设 UUID。
    var deviceBluetoothIdentifier: String? {
        connectedPeripheral?.identifier.uuidString
    }

    // MARK: - 硬件 SN 本地缓存

    /// 断连时 `deviceSN` 会被清空，但解绑接口仍要求上报 `sn`。
    /// 因此配对成功后按 `serial_number`（BLE UUID）持久化硬件 SN，解绑时从本地读。
    private static let cachedHardwareSNMapKey = "AstraA1CachedHardwareSNMap"

    private var cachedHardwareSNMap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.cachedHardwareSNMapKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.cachedHardwareSNMapKey) }
    }

    private static func normalizedSNKey(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }

    /// 记录 serial_number → 硬件 SN，供断连后解绑使用。
    func cacheHardwareSN(serialNumber: String?, sn: String?) {
        guard let key = Self.normalizedSNKey(serialNumber),
              let sn = sn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sn.isEmpty else { return }
        var map = cachedHardwareSNMap
        guard map[key] != sn else { return }
        map[key] = sn
        cachedHardwareSNMap = map
        print("\(logTag) cached hardware SN serial_number=\(key) sn=\(sn)")
    }

    /// 读取本地缓存的硬件 SN；未指定 serial_number 且只缓存过一副眼镜时回退到唯一值。
    func cachedHardwareSN(forSerialNumber serialNumber: String?) -> String? {
        let map = cachedHardwareSNMap
        if let key = Self.normalizedSNKey(serialNumber), let sn = map[key] {
            return sn
        }
        // An explicit target must never inherit another glasses' SN.
        if Self.normalizedSNKey(serialNumber) != nil { return nil }
        return map.count == 1 ? map.values.first : nil
    }

    /// 解绑成功后清掉缓存，避免重新绑定其它眼镜时命中旧 SN。
    func forgetCachedHardwareSN(forSerialNumber serialNumber: String?) {
        guard let key = Self.normalizedSNKey(serialNumber) else {
            UserDefaults.standard.removeObject(forKey: Self.cachedHardwareSNMapKey)
            return
        }
        var map = cachedHardwareSNMap
        map.removeValue(forKey: key)
        cachedHardwareSNMap = map
    }

    // MARK: - Media Import BLE Commands

    enum ImportBLEError: LocalizedError {
        case notReady
        case sendFailed
        case timeout
        case openWifiRejected
        case truncated
        case failed(String)

        var isTimeout: Bool {
            if case .timeout = self { return true }
            return false
        }

        /// toopenwifi 超时、被设备拒绝、wificonfig 补读失败，都可以 closewifi 后重开一次。
        var isOpenWifiRetryable: Bool {
            switch self {
            case .timeout, .openWifiRejected, .truncated: return true
            default: return false
            }
        }

        /// 长包收不全：超时多半也是等不到完整 wificonfig 导致的。
        var isTruncationRelated: Bool {
            switch self {
            case .truncated, .timeout: return true
            default: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .notReady: return L10n.t("设备未连接", "Device not connected")
            case .sendFailed: return L10n.t("发送命令失败", "Failed to send command")
            case .timeout: return L10n.t("等待设备响应超时", "Device response timed out")
            case .openWifiRejected: return L10n.t("眼镜开启热点失败", "Glasses failed to start hotspot")
            case .truncated: return L10n.t("Wi-Fi 配置读取失败（BLE 数据被截断）", "Failed to read Wi-Fi config (BLE data truncated)")
            case .failed(let message): return message
            }
        }
    }

    /// 开启眼镜 Wi-Fi，并等待 wificonfig 通知。
    /// 首次超时则 closewifi 后再重试一次 toopenwifi。
    /// - Parameter purpose: `.fileImport` 导图；`.ota` 固件升级。
    func openWifiAndWaitConfig(
        purpose: AstraA1BleProtocol.OpenWifiPurpose,
        timeout: TimeInterval = 15
    ) async throws -> AstraA1BleProtocol.WifiConfig {
        wifiLog(
            "请求眼镜开启热点",
            detail: "purpose=\(purpose.rawValue)\ntimeout=\(String(format: "%.1f", timeout))s\nbleReady=\(isReady)",
            direction: .sent
        )
        do {
            let config = try await openWifiAndWaitConfigOnce(purpose: purpose, timeout: timeout)
            wifiLog(
                "眼镜热点配置已获取",
                detail: "purpose=\(purpose.rawValue)\nssid=\(config.ssid ?? "nil")\npasswordEmpty=\((config.password ?? "").isEmpty)\nhttp=\(config.httpAddress ?? "nil")",
                direction: .received
            )
            return config
        } catch let error as ImportBLEError where error.isOpenWifiRetryable {
            print("\(logTag) toopenwifi \(error.localizedDescription), closewifi then retry once purpose=\(purpose.rawValue)")
            wifiLog(
                "首次开启热点失败，关闭后重试",
                detail: "purpose=\(purpose.rawValue)\nerror=\(error.localizedDescription)",
                direction: .received
            )
            do {
                try await closeWifi()
                print("\(logTag) closewifi ack ok before open retry")
            } catch {
                print("\(logTag) closewifi before open retry: \(error.localizedDescription), continue toopenwifi")
                wifiLog(
                    "重试前关闭热点失败，继续重试",
                    detail: "error=\(error.localizedDescription)",
                    direction: .received
                )
            }
            do {
                let config = try await openWifiAndWaitConfigOnce(purpose: purpose, timeout: timeout)
                wifiLog(
                    "重试后获取热点配置成功",
                    detail: "purpose=\(purpose.rawValue)\nssid=\(config.ssid ?? "nil")\npasswordEmpty=\((config.password ?? "").isEmpty)\nhttp=\(config.httpAddress ?? "nil")",
                    direction: .received
                )
                return config
            } catch let retryError as ImportBLEError where retryError.isTruncationRelated {
                // 长包一直收不全：重建链路重协商 MTU 后再试最后一次。
                guard !hasRelinkedForLongPackets else {
                    wifiLog(
                        "热点配置重试失败",
                        detail: "purpose=\(purpose.rawValue)\nerror=\(retryError.localizedDescription)\nrelinkAlreadyUsed=true",
                        direction: .received
                    )
                    throw retryError
                }
                hasRelinkedForLongPackets = true
                wifiLog(
                    "热点配置包不完整，重建 BLE 链路",
                    detail: "error=\(retryError.localizedDescription)",
                    direction: .sent
                )
                guard await relinkForLongPackets() else {
                    wifiLog("BLE 链路重建失败", detail: "purpose=\(purpose.rawValue)", direction: .received)
                    throw retryError
                }
                try? await closeWifi()
                do {
                    let config = try await openWifiAndWaitConfigOnce(purpose: purpose, timeout: timeout)
                    wifiLog(
                        "BLE 重建后获取热点配置成功",
                        detail: "purpose=\(purpose.rawValue)\nssid=\(config.ssid ?? "nil")\npasswordEmpty=\((config.password ?? "").isEmpty)\nhttp=\(config.httpAddress ?? "nil")",
                        direction: .received
                    )
                    return config
                } catch {
                    wifiLog(
                        "BLE 重建后仍无法获取热点配置",
                        detail: "purpose=\(purpose.rawValue)\nerror=\(error.localizedDescription)",
                        direction: .received
                    )
                    throw error
                }
            } catch {
                wifiLog(
                    "再次开启热点失败",
                    detail: "purpose=\(purpose.rawValue)\nerror=\(error.localizedDescription)",
                    direction: .received
                )
                throw error
            }
        } catch {
            wifiLog(
                "开启眼镜热点失败",
                detail: "purpose=\(purpose.rawValue)\nerror=\(error.localizedDescription)",
                direction: .received
            )
            throw error
        }
    }

    /// 重建 LE 链路，让 iOS 重新协商 ATT MTU。
    /// 接管系统已建立的连接时不会重新协商，设备仍按 20 字节发 notify，长包（wificonfig
    /// 声明 100 字节 payload）会被截断且无续包；安卓靠 requestMtu(512) 规避，iOS 无对应 API。
    func relinkForLongPackets(timeout: TimeInterval = 20) async -> Bool {
        guard let peripheral = connectedPeripheral else { return false }
        guard !isRelinkingForLongPackets else { return false }
        isRelinkingForLongPackets = true
        defer { isRelinkingForLongPackets = false }

        print("\(logTag) relink for long packets: disconnect \(peripheral.identifier.uuidString)")
        // 主动断开期间别让站岗 connect 抢先把链路接回去。
        cancelAutomaticGATTRecovery(reason: "relink-for-long-packets", resetAttempts: true)
        userInitiatedDisconnect = true
        autoReconnectEnabled = false
        standingConnectPeripheralID = nil
        standingConnectRecoveryCount = 0
        centralManager.cancelPeripheralConnection(peripheral)

        // 等链路真正断开，否则重连只是复用旧连接，MTU 不会重协商。
        let disconnectDeadline = Date().addingTimeInterval(5)
        while Date() < disconnectDeadline, peripheral.state != .disconnected {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        userInitiatedDisconnect = false
        autoReconnectEnabled = true
        standingConnectAllowed = true
        resetConnectionHandles()
        print("\(logTag) relink for long packets: reconnect")
        attachToConnectedPeripheral(peripheral)

        let readyDeadline = Date().addingTimeInterval(timeout)
        while Date() < readyDeadline {
            if isReady {
                if let mtu = connectedPeripheral?.maximumWriteValueLength(for: .withoutResponse) {
                    print("\(logTag) relink done, maxWrite withoutResponse=\(mtu)")
                }
                return true
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        print("\(logTag) relink for long packets timed out")
        return false
    }

    private func openWifiAndWaitConfigOnce(
        purpose: AstraA1BleProtocol.OpenWifiPurpose,
        timeout: TimeInterval
    ) async throws -> AstraA1BleProtocol.WifiConfig {
        guard ensureDeviceAvailable(for: "openWifiAndWaitConfigOnce") else {
            wifiLog("无法开启热点：当前没有可用设备", detail: "purpose=\(purpose.rawValue)", direction: .received)
            throw ImportBLEError.notReady
        }
        await waitWifiReopenCooldown()
        notifyReadAttempts = 0
        return try await withCheckedThrowingContinuation { continuation in
            wifiConfigContinuation = continuation
            self.wifiLog(
                "发送 toopenwifi",
                detail: "purpose=\(purpose.rawValue)\ntimeout=\(String(format: "%.1f", timeout))s",
                direction: .sent
            )
            guard sendCommand(AstraA1BleProtocol.buildToOpenWifiCommand(purpose: purpose)) else {
                wifiConfigContinuation = nil
                self.wifiLog("发送 toopenwifi 失败", detail: "purpose=\(purpose.rawValue)", direction: .received)
                continuation.resume(throwing: ImportBLEError.sendFailed)
                return
            }
            scheduleImportTimeout(seconds: timeout) { [weak self] in
                guard let self, let cont = self.wifiConfigContinuation else { return }
                self.wifiConfigContinuation = nil
                self.wifiLog(
                    "等待 wificonfig 超时",
                    detail: "purpose=\(purpose.rawValue)\ntimeout=\(String(format: "%.1f", timeout))s",
                    direction: .received
                )
                cont.resume(throwing: ImportBLEError.timeout)
            }
        }
    }

    /// 仅发 toopenwifi 并等待状态回包（13 字节）。
    func openWifiAwaitStatus(purpose: AstraA1BleProtocol.OpenWifiPurpose) async throws {
        guard ensureDeviceAvailable(for: "openWifiAwaitStatus") else { throw ImportBLEError.notReady }
        notifyReadAttempts = 0
        _ = try await waitStatusResponse(command: "toopenwifi") {
            self.sendCommand(AstraA1BleProtocol.buildToOpenWifiCommand(purpose: purpose))
        }
    }

    /// Wi-Fi 凭据缓存键：优先设备 SN，其次外设 identifier。
    private var wifiCredentialKey: String? {
        if let sn = deviceSN?.trimmingCharacters(in: .whitespacesAndNewlines), !sn.isEmpty {
            return sn
        }
        return connectedPeripheral?.identifier.uuidString
    }

    /// 读取当前设备已缓存的热点凭据（若有）。
    func cachedWifiCredential() -> GlassesWifiCredential? {
        guard let key = wifiCredentialKey else { return nil }
        return GlassesWifiCredentialStore.load(deviceKey: key)
    }

    /// 缓存失效（用缓存连热点失败）时清除，触发下次重新解析 wificonfig。
    func invalidateCachedWifiCredential() {
        guard let key = wifiCredentialKey else { return }
        GlassesWifiCredentialStore.remove(deviceKey: key)
        print("\(logTag) wifi credential invalidated for key=\(key)")
    }

    /// 收到完整（未截断）wificonfig 时按 SN 缓存热点凭据。
    private func cacheWifiCredentialIfPossible(_ config: AstraA1BleProtocol.WifiConfig) {
        guard let key = wifiCredentialKey else { return }
        guard let ssid = config.ssid?.trimmingCharacters(in: .whitespacesAndNewlines), !ssid.isEmpty else { return }
        let credential = GlassesWifiCredential(
            ssid: ssid,
            password: config.password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            httpAddress: config.httpAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "http://192.168.0.1/"
        )
        GlassesWifiCredentialStore.save(deviceKey: key, credential: credential)
        print("\(logTag) wifi credential cached for key=\(key) ssid=\(ssid)")
    }

    /// 首次配对后曾用于预缓存热点；现改为每次从 wificonfig 取凭据，此预热不再执行。
    private func seedWifiCredentialIfNeeded() {
        guard deviceGeneration == .gen2 else { return }
        // no-op：导入/OTA 统一 toopenwifi → wificonfig。
    }

    /// 获取下载 HTTP 路径。
    func getDownloadWorkPath(timeout: TimeInterval = 10) async throws -> String {
        try await getWorkPath(pathType: 0x01, timeout: timeout)
    }

    /// 获取 OTA 上传 HTTP 路径（pathType = 0x02）。
    func getOtaWorkPath(timeout: TimeInterval = 10) async throws -> String {
        try await getWorkPath(pathType: 0x02, timeout: timeout)
    }

    /// 获取算法 DLL 上传 HTTP 路径（pathType = 0x04）。
    func getDLLWorkPath(timeout: TimeInterval = 10) async throws -> String {
        try await getWorkPath(pathType: 0x04, timeout: timeout)
    }

    /// 蓝牙 OTA 前查询眼镜现有 DLL。长回包按 iOS MTU 兜底重连一次。
    func queryAlgorithmInfo(timeout: TimeInterval = 10) async throws -> [AstraA1BleProtocol.DeviceAlgorithmInfo] {
        do {
            return try await queryAlgorithmInfoOnce(timeout: timeout)
        } catch let error as ImportBLEError {
            guard case .truncated = error else { throw error }
            guard !hasRelinkedForLongPackets else { throw error }
            hasRelinkedForLongPackets = true
            guard await relinkForLongPackets() else { throw error }
            return try await queryAlgorithmInfoOnce(timeout: timeout)
        }
    }

    private func queryAlgorithmInfoOnce(timeout: TimeInterval) async throws -> [AstraA1BleProtocol.DeviceAlgorithmInfo] {
        guard isReady else { throw ImportBLEError.notReady }
        notifyReadAttempts = 0
        return try await withCheckedThrowingContinuation { continuation in
            algorithmInfoContinuation = continuation
            guard sendCommand(AstraA1BleProtocol.buildGetAlgorithmInfoCommand()) else {
                algorithmInfoContinuation = nil
                continuation.resume(throwing: ImportBLEError.sendFailed)
                return
            }
            scheduleImportTimeout(seconds: timeout) { [weak self] in
                guard let self, let cont = self.algorithmInfoContinuation else { return }
                self.algorithmInfoContinuation = nil
                cont.resume(throwing: ImportBLEError.timeout)
            }
        }
    }

    /// DLL 文件已上传后，下发 dllupload0 并等待 dllupdrsp0。
    func waitForDLLInstall(
        items: [AstraA1BleProtocol.DLLUploadItem],
        timeout: TimeInterval = 120,
        onProgress: ((Int) -> Void)? = nil
    ) async throws -> AstraA1BleProtocol.DLLUpdateResult {
        guard ensureDeviceAvailable(for: "waitForDLLInstall") else { throw ImportBLEError.notReady }
        guard let command = AstraA1BleProtocol.buildDLLUploadCommand(items: items) else {
            throw ImportBLEError.failed(L10n.t("算法文件安装参数无效", "Invalid algorithm install parameters"))
        }
        return try await withCheckedThrowingContinuation { continuation in
            dllUpdateContinuation = continuation
            dllProgressHandler = onProgress
            guard sendCommand(command) else {
                dllUpdateContinuation = nil
                dllProgressHandler = nil
                continuation.resume(throwing: ImportBLEError.sendFailed)
                return
            }
            if let id = connectedPeripheral?.identifier {
                gen2OtaRecovery.markAlgorithmInstallSubmitted(to: id)
            }
            scheduleImportTimeout(seconds: timeout) { [weak self] in
                guard let self, let cont = self.dllUpdateContinuation else { return }
                self.dllUpdateContinuation = nil
                self.dllProgressHandler = nil
                cont.resume(throwing: ImportBLEError.timeout)
            }
        }
    }

    private func getWorkPath(pathType: UInt8, timeout: TimeInterval) async throws -> String {
        guard isReady else { throw ImportBLEError.notReady }
        notifyReadAttempts = 0
        return try await withCheckedThrowingContinuation { continuation in
            workPathContinuation = continuation
            guard sendCommand(AstraA1BleProtocol.buildGetWorkPathCommand(pathType: pathType)) else {
                workPathContinuation = nil
                continuation.resume(throwing: ImportBLEError.sendFailed)
                return
            }
            scheduleImportTimeout(seconds: timeout) { [weak self] in
                guard let self, let cont = self.workPathContinuation else { return }
                self.workPathContinuation = nil
                cont.resume(throwing: ImportBLEError.timeout)
            }
        }
    }

    /// 发送 otaupload0，启动蓝牙固件升级。
    func startBluetoothOtaUpgrade(fileName: String) throws {
        guard ensureDeviceAvailable(for: "startBluetoothOtaUpgrade") else { throw ImportBLEError.notReady }
        guard isDeviceRuntimeIdle || deviceRuntimeStatus == .firmwareUpgrading else {
            throw ImportBLEError.failed(deviceRuntimeStatus.busyMessage)
        }
        guard sendCommand(AstraA1BleProtocol.buildOtaUploadBluetoothCommand(fileName: fileName)) else {
            throw ImportBLEError.sendFailed
        }
        if let id = connectedPeripheral?.identifier { gen2OtaRecovery.markUpgradeSubmitted(to: id) }
        print("\(logTag) otaupload0 sent file=\(fileName)")
    }

    /// 发送 otaupload1，启动主固件升级。
    func startFirmwareOtaUpgrade(fileName: String) throws {
        guard ensureDeviceAvailable(for: "startFirmwareOtaUpgrade") else { throw ImportBLEError.notReady }
        guard isDeviceRuntimeIdle || deviceRuntimeStatus == .firmwareUpgrading else {
            throw ImportBLEError.failed(deviceRuntimeStatus.busyMessage)
        }
        guard sendCommand(AstraA1BleProtocol.buildOtaUploadFirmwareCommand(fileName: fileName)) else {
            throw ImportBLEError.sendFailed
        }
        if let id = connectedPeripheral?.identifier { gen2OtaRecovery.markUpgradeSubmitted(to: id) }
        print("\(logTag) otaupload1 sent file=\(fileName)")
    }

    /// 发送 otaupload 并等待 otaprogres 到 100%。
    /// 必须先挂回调再发包，否则设备秒回的进度会被丢掉（对齐安卓 UPGRADING 态常开收包）。
    func waitForOtaUpgradeCompletion(
        timeout: TimeInterval = 180,
        onProgress: ((Int) -> Void)? = nil,
        sendUpgradeCommand: () throws -> Void
    ) async throws {
        guard ensureDeviceAvailable(for: "waitForOtaUpgradeCompletion") else { throw ImportBLEError.notReady }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard otaUpgradeContinuation == nil else {
                continuation.resume(throwing: ImportBLEError.failed(L10n.t("已有升级正在等待结果", "An update is already awaiting its result")))
                return
            }
            let waitID = UUID()
            otaUpgradeWaitID = waitID
            otaProgressDeadline = Gen2OtaProgressDeadline(now: ProcessInfo.processInfo.systemUptime)
            wifiLog("升级：开始等待设备进度", detail: "target=\(connectedPeripheral?.identifier.uuidString ?? "nil") wait=\(waitID) inactivityTimeout=\(timeout)s maximum=900s")
            otaUpgradeContinuation = continuation
            otaUpgradeProgressHandler = onProgress
            do {
                try sendUpgradeCommand()
            } catch {
                otaUpgradeContinuation = nil
                otaUpgradeProgressHandler = nil
                otaUpgradeWaitID = nil
                otaProgressDeadline = nil
                continuation.resume(throwing: error)
                return
            }
            otaUpgradeTimeoutTask?.cancel()
            otaUpgradeTimeoutTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self, self.otaUpgradeWaitID == waitID,
                          let deadline = self.otaProgressDeadline else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard deadline.hasExpired(now: now, inactivity: timeout) else { continue }
                    guard let cont = self.otaUpgradeContinuation else { return }
                    self.otaUpgradeContinuation = nil
                    self.otaUpgradeProgressHandler = nil
                    self.otaUpgradeWaitID = nil
                    self.otaProgressDeadline = nil
                    self.wifiLog("升级：进度等待超时", detail: "wait=\(waitID) elapsed=\(now - deadline.startedAt)s idle=\(now - deadline.lastProgressAt)s; verify version before declaring failure")
                    cont.resume(throwing: ImportBLEError.timeout)
                    return
                }
            }
        }
    }

    private func completeOtaUpgradeIfNeeded(percent: Int) {
        // Progress is evidence of device-side flashing even if the initiating command
        // or its reply was missed. Do not cancel such a session during later cleanup.
        if deviceGeneration == .gen2, let id = connectedPeripheral?.identifier {
            gen2OtaRecovery.receiveProgress(from: id, percent: percent)
            gen2OtaLastProgressAt = ProcessInfo.processInfo.systemUptime
        }
        otaProgressDeadline?.receivedProgress(now: ProcessInfo.processInfo.systemUptime)
        wifiLog("升级：设备进度", detail: "target=\(connectedPeripheral?.identifier.uuidString ?? "nil") progress=\(percent) waiter=\(otaUpgradeWaitID?.uuidString ?? "nil")", direction: .received)
        print("\(logTag) OTA progress=\(percent)% waiter=\(otaUpgradeContinuation != nil)")
        otaUpgradeProgressHandler?(percent)
        guard percent >= 100, let cont = otaUpgradeContinuation else { return }
        otaUpgradeContinuation = nil
        otaUpgradeProgressHandler = nil
        otaUpgradeTimeoutTask?.cancel()
        otaUpgradeTimeoutTask = nil
        otaUpgradeWaitID = nil
        otaProgressDeadline = nil
        cont.resume()
    }

    func sendTransferOK(success: Bool) {
        _ = sendCommand(AstraA1BleProtocol.buildTransferOKCommand(success: success))
    }

    /// 同步眼镜时间（开始 AI 录音前调用）。
    @discardableResult
    func syncAIRecordTime() -> Bool {
        guard ensureDeviceAvailable(for: "syncAIRecordTime") else { return false }
        let sent = sendCommand(AstraA1BleProtocol.buildSyncTimeCommand())
        print("\(logTag) synctime00 sent=\(sent)")
        return sent
    }

    /// 开始眼镜 AI 录音：空闲校验 → 对时 → 延迟约 180ms → airecord00=1。
    @discardableResult
    func startAIRecord() -> Bool {
        guard ensureDeviceAvailable(for: "startAIRecord") else {
            mediaActionAlertMessage = L10n.t("设备未连接", "Device not connected")
            return false
        }
        guard !isBatteryTooLowForMedia else {
            mediaActionAlertMessage = lowBatteryMediaMessage
            return false
        }
        if deviceRuntimeStatus != .standby, deviceRuntimeStatus != .unknown {
            mediaActionAlertMessage = deviceRuntimeStatus.busyMessage
            return false
        }
        if isAIRecording {
            return true
        }
        let recordingPeripheralID = deviceBluetoothIdentifier
        _ = syncAIRecordTime()
        // 对齐 Android AiRecordingActivity：对时后短暂等待再开录。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            guard self.ensureDeviceAvailable(for: "startAIRecord-delayed"), self.deviceBluetoothIdentifier == recordingPeripheralID else {
                self.mediaActionAlertMessage = L10n.t("设备未连接", "Device not connected")
                return
            }
            guard !self.isBatteryTooLowForMedia else {
                self.mediaActionAlertMessage = self.lowBatteryMediaMessage
                return
            }
            if self.deviceRuntimeStatus != .standby, self.deviceRuntimeStatus != .unknown {
                self.mediaActionAlertMessage = self.deviceRuntimeStatus.busyMessage
                return
            }
            let sent = self.sendCommand(AstraA1BleProtocol.buildAIRecordCommand(enable: true))
            print("\(self.logTag) airecord00 start sent=\(sent)")
            if sent {
                self.isAIRecording = true
            } else {
                self.mediaActionAlertMessage = L10n.t("开始录音失败，请重试", "Failed to start recording. Try again.")
            }
        }
        return true
    }

    /// 停止眼镜 AI 录音。
    @discardableResult
    func stopAIRecord() -> Bool {
        guard isReady else {
            isAIRecording = false
            return false
        }
        let sent = sendCommand(AstraA1BleProtocol.buildAIRecordCommand(enable: false))
        if deviceGeneration == .gen1G5K61 { return sent }
        print("\(logTag) airecord00 stop sent=\(sent)")
        isAIRecording = false
        if sent {
            finishRuntimeOperationIfNeeded(
                expected: .voiceRecording,
                fallback: .unknown,
                reason: "ai-record-stop"
            )
        }
        return sent
    }

    func noteImportedRecordingFiles(count: Int = 0) {
        if count > 0 {
            let before = pendingRecordingImportFileCount
            pendingRecordingImportFileCount = max(0, pendingRecordingImportFileCount - count)
            print("\(logTag) noteImportedRecordingFiles -\(count) pending \(before) -> \(pendingRecordingImportFileCount)")
        } else {
            pendingRecordingImportFileCount = 0
            print("\(logTag) noteImportedRecordingFiles cleared")
        }
        persistPendingRecordingCount(pendingRecordingImportFileCount)
    }

    /// 录音页：删除失败残留时，本地维持待导入数量以便再次显示导入条。
    func applyPendingRecordingImportCount(_ count: Int) {
        pendingRecordingImportFileCount = max(0, count)
        persistPendingRecordingCount(pendingRecordingImportFileCount)
        print("\(logTag) applyPendingRecordingImportCount=\(pendingRecordingImportFileCount)")
    }

    private func persistPendingRecordingCount(_ count: Int) {
        if count > 0 {
            UserDefaults.standard.set(count, forKey: pendingRecordingCountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pendingRecordingCountKey)
        }
    }

    /// 读取设备当前音效。先恢复当前设备缓存，回包后再以设备值覆盖。
    @discardableResult
    func querySoundEffectMode() -> Bool {
        guard isReady else {
            mediaActionAlertMessage = L10n.t("请先连接眼镜", "Connect glasses first")
            return false
        }
        restoreCachedSoundEffectMode()
        let sent = sendCommand(AstraA1BleProtocol.buildGetEQModeCommand())
        print("\(logTag) geteqmode0 sent=\(sent)")
        if !sent {
            mediaActionAlertMessage = L10n.t("音效模式查询失败", "Failed to query sound mode")
        }
        return sent
    }

    /// 设置设备音效；发送成功立即更新 UI，eqmodersp0 回包再校正设备实际值。
    @discardableResult
    func setSoundEffectMode(_ mode: UInt8) -> Bool {
        guard ensureDeviceAvailable(for: "setSoundEffectMode") else {
            mediaActionAlertMessage = L10n.t("请先连接眼镜", "Connect glasses first")
            return false
        }
        let safeMode = min(mode, 2)
        let sent = sendCommand(AstraA1BleProtocol.buildSetEQModeCommand(mode: safeMode))
        print("\(logTag) seteqmode0 mode=\(safeMode) sent=\(sent)")
        if sent {
            // Some firmware versions do not immediately emit eqmodersp0 after
            // seteqmode0. Update published state on successful BLE submission so
            // the home card reflects the user's selection immediately; a later
            // device response remains authoritative and can correct it.
            soundEffectMode = safeMode
            persistSoundEffectMode(safeMode)
        } else {
            mediaActionAlertMessage = L10n.t("音效模式设置失败", "Failed to set sound mode")
        }
        return sent
    }

    @discardableResult
    func startAIVoice(continuous: Bool = true) -> Bool {
        guard ensureDeviceAvailable(for: "startAIVoice") else {
            mediaActionAlertMessage = L10n.t("请先连接眼镜", "Connect glasses first")
            return false
        }
        if deviceRuntimeStatus != .standby, deviceRuntimeStatus != .unknown {
            mediaActionAlertMessage = deviceRuntimeStatus.busyMessage
            return false
        }
        let sent = sendCommand(
            AstraA1BleProtocol.buildAIVoiceCommand(enable: true, continuous: continuous)
        )
        print("\(logTag) aivoice000 start continuous=\(continuous) sent=\(sent)")
        if !sent {
            mediaActionAlertMessage = L10n.t("语音提问开启失败，请重试", "Failed to start voice Q&A. Try again.")
        }
        return sent
    }

    @discardableResult
    func stopAIVoice() -> Bool {
        guard isReady else { return false }
        let sent = sendCommand(AstraA1BleProtocol.buildAIVoiceCommand(enable: false))
        print("\(logTag) aivoice000 stop sent=\(sent)")
        if !sent {
            mediaActionAlertMessage = L10n.t("语音提问关闭失败，请重试", "Failed to stop voice Q&A. Try again.")
        } else {
            finishRuntimeOperationIfNeeded(
                expected: .voiceRecording,
                fallback: .unknown,
                reason: "ai-voice-stop"
            )
        }
        return sent
    }

    @discardableResult
    func setAIVoiceListeningDuration(seconds: Int) -> Bool {
        guard deviceGeneration == .gen2 else { return false }
        guard ensureDeviceAvailable(for: "setAIVoiceListeningDuration") else {
            mediaActionAlertMessage = L10n.t("请先连接眼镜", "Connect glasses first")
            return false
        }
        guard let command = AstraA1BleProtocol.buildSetAIVoiceListeningDurationCommand(seconds: seconds) else {
            return false
        }
        let sent = sendCommand(command)
        print("\(logTag) setaivsil0 seconds=\(seconds) sent=\(sent)")
        return sent
    }

    @discardableResult
    func queryAIVoiceListeningDuration() -> Bool {
        guard deviceGeneration == .gen2 else { return false }
        guard isReady else { return false }
        let sent = sendCommand(AstraA1BleProtocol.buildGetAIVoiceListeningDurationCommand())
        print("\(logTag) getaivsil0 sent=\(sent)")
        return sent
    }

    @discardableResult
    func setVoiceWakeupEnabled(_ enabled: Bool) -> Bool {
        guard deviceGeneration == .gen2 else { return false }
        guard ensureDeviceAvailable(for: "setVoiceWakeupEnabled") else {
            mediaActionAlertMessage = L10n.t("请先连接眼镜", "Connect glasses first")
            return false
        }
        let sent = sendCommand(AstraA1BleProtocol.buildSetVoiceWakeupCommand(enabled: enabled))
        print("\(logTag) setwakeup0 enabled=\(enabled) sent=\(sent)")
        return sent
    }

    @discardableResult
    func queryVoiceWakeupEnabled() -> Bool {
        guard deviceGeneration == .gen2 else { return false }
        guard isReady else { return false }
        let sent = sendCommand(AstraA1BleProtocol.buildGetVoiceWakeupCommand())
        print("\(logTag) getwakeup0 sent=\(sent)")
        return sent
    }

    @discardableResult
    func resumeAIVoiceListening() -> Bool {
        guard deviceGeneration == .gen2 else { return false }
        guard ensureDeviceAvailable(for: "resumeAIVoiceListening") else { return false }
        let sent = sendCommand(AstraA1BleProtocol.buildResumeAIVoiceListeningCommand())
        print("\(logTag) aivlisten0 sent=\(sent)")
        return sent
    }

    @discardableResult
    func startTranslateRecording() -> Bool {
        guard ensureDeviceAvailable(for: "startTranslateRecording") else {
            mediaActionAlertMessage = L10n.t("请先连接眼镜", "Connect glasses first")
            return false
        }
        if deviceGeneration == .gen1G5K61, gen1VoiceCharacteristic?.isNotifying != true {
            if let peripheral = connectedPeripheral, let voice = gen1VoiceCharacteristic {
                peripheral.setNotifyValue(true, for: voice)
            }
            DebugLogStore.logBLEEvent("Gen1 translation START blocked", detail: "AE3D audio notifications are not ready; resubscription requested")
            mediaActionAlertMessage = L10n.t("眼镜录音通道尚未就绪，请稍后重试", "Glasses audio channel is not ready. Try again shortly.")
            return false
        }
        DebugLogStore.logBLEEvent("translation START requested", detail: "generation=\(deviceGeneration.rawValue) voiceNotifying=\(gen1VoiceCharacteristic?.isNotifying == true) status=\(deviceRuntimeStatus)")
        if deviceRuntimeStatus != .standby, deviceRuntimeStatus != .unknown {
            mediaActionAlertMessage = deviceRuntimeStatus.busyMessage
            return false
        }
        let sent = sendCommand(AstraA1BleProtocol.buildTranslateRecordCommand(enable: true))
        print("\(logTag) trslate000 start sent=\(sent)")
        if !sent {
            mediaActionAlertMessage = L10n.t("眼镜录音开启失败，请重试", "Failed to start glasses recording. Try again.")
        }
        return sent
    }

    @discardableResult
    func stopTranslateRecording() -> Bool {
        guard isReady else {
            DebugLogStore.logBLEEvent("translation STOP rejected", detail: "reason=BLE_not_ready target=\(deviceBluetoothIdentifier ?? "nil")")
            return false
        }
        let sent = sendCommand(AstraA1BleProtocol.buildTranslateRecordCommand(enable: false))
        DebugLogStore.logBLEEvent("translation STOP requested", detail: "generation=\(deviceGeneration.rawValue) target=\(deviceBluetoothIdentifier ?? "nil") sent=\(sent) requires_audio_END=\(deviceGeneration == .gen1G5K61)")
        print("\(logTag) trslate000 stop sent=\(sent)")
        if sent {
            finishRuntimeOperationIfNeeded(
                expected: .voiceRecording,
                fallback: .unknown,
                reason: "translation-record-stop"
            )
        }
        return sent
    }

    private var soundEffectStorageKey: String? {
        let raw = deviceSN?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceKey = (raw?.isEmpty == false ? raw : connectedPeripheral?.identifier.uuidString)
        guard let deviceKey, !deviceKey.isEmpty else { return nil }
        let normalized = deviceKey.lowercased().replacingOccurrences(of: " ", with: "_")
        return "sound_effect_mode_\(normalized)"
    }

    private func restoreCachedSoundEffectMode() {
        guard let key = soundEffectStorageKey,
              UserDefaults.standard.object(forKey: key) != nil else { return }
        soundEffectMode = UInt8(clamping: UserDefaults.standard.integer(forKey: key))
        if soundEffectMode > 2 { soundEffectMode = 0 }
    }

    private func applySoundEffectResponse(status: UInt8, mode: UInt8) {
        soundEffectMode = mode
        persistSoundEffectMode(mode)
        print("\(logTag) eqmodersp0 status=\(status) mode=\(mode)")
        if status != 0 {
            mediaActionAlertMessage = L10n.t("音效模式设置失败", "Failed to set sound mode")
        }
    }

    private func persistSoundEffectMode(_ mode: UInt8) {
        guard let key = soundEffectStorageKey else { return }
        UserDefaults.standard.set(Int(min(mode, 2)), forKey: key)
    }

    /// 发送拍照指令；业务是否接受以 actionrsp0 为准。
    @discardableResult
    func takePhoto() -> Bool {
        guard ensureDeviceAvailable(for: "takePhoto") else { return false }
        guard !isBatteryTooLowForMedia else {
            mediaActionAlertMessage = lowBatteryMediaMessage
            return false
        }
        let sent = sendCommand(AstraA1BleProtocol.buildTakePhotoCommand())
        if sent, deviceGeneration == .gen1G5K61,
           let id = homePhotoAttemptID, isTakingPhoto,
           let target = deviceBluetoothIdentifier.flatMap(UUID.init(uuidString:)),
           let account = gen1ImportAccount(for: target) {
            let configuration = PhotoWatermarkConfiguration(enabled: AppSettings.imageWatermarkEnabled,
                style: AppSettings.imageWatermarkStyle, capturedAt: Date())
            let saved = PhotoCaptureWatermarkStore.shared.begin(id: id, account: account,
                device: target.uuidString, baselineNames: gen1MediaListAccumulator.names,
                baselineCount: pendingImportFileCount, configuration: configuration)
            logPhotoCapture("watermark-snapshot", detail: "saved=\(saved) enabled=\(configuration.enabled) style=\(configuration.style) cachedFileCount=\(gen1MediaListAccumulator.names.count)")
        }
        return sent
    }

    /// 开始录像；业务是否接受以 actionrsp0 为准。
    @discardableResult
    func startVideo() -> Bool {
        guard ensureDeviceAvailable(for: "startVideo") else { return false }
        guard !isBatteryTooLowForMedia else {
            mediaActionAlertMessage = lowBatteryMediaMessage
            return false
        }
        isHomeVideoStartInProgress = true
        defer { isHomeVideoStartInProgress = false }
        return sendCommand(AstraA1BleProtocol.buildStartVideoCommand())
    }

    /// 手动停止录像；命令回包不代表结束，以设备空闲状态确认完成。
    @discardableResult
    func stopVideo() -> Bool {
        guard isReady else { return false }
        return sendCommand(AstraA1BleProtocol.buildStopVideoCommand())
    }

    private var homePhotoAttemptID: UUID?
    private var homePhotoObservedTaking = false
    private var homePhotoBaselineCount = 0

    private func logPhotoCapture(_ event: String, detail: String = "") {
        DebugLogStore.logBLEEvent("Photo capture \(event)", detail: "attempt=\(homePhotoAttemptID?.uuidString ?? "none") target=\(deviceBluetoothIdentifier ?? "none") generation=\(deviceGeneration) runtime=\(deviceRuntimeStatus.name) pending=\(isTakingPhoto) observedTaking=\(homePhotoObservedTaking) baselineCount=\(homePhotoBaselineCount) currentCount=\(pendingImportFileCount) \(detail)")
    }

    func takePhotoFromHome() {
        guard !isBatteryTooLowForMedia else {
            mediaActionAlertMessage = lowBatteryMediaMessage
            return
        }
        guard ensureMediaActionAllowed(busy: isTakingPhoto || photoCompleted) else { return }
        homePhotoAttemptID = UUID()
        homePhotoObservedTaking = false
        homePhotoBaselineCount = pendingImportFileCount
        isTakingPhoto = true
        photoCompleted = false
        logPhotoCapture("request", detail: "command=takephoto0 gen1Command=0x60")
        guard takePhoto() else {
            logPhotoCapture("send-failed", detail: "completion=false")
            isTakingPhoto = false
            mediaActionAlertMessage = L10n.t("发送拍照命令失败，请重试", "Failed to send photo command. Try again.")
            return
        }
        logPhotoCapture("sent", detail: "writeQueued=true deviceCompletionConfirmed=false")
        // A queued write does not confirm device execution.
        // 旧固件不回 devstatus0/actionrsp0 时，也不能让本地 busy 永久卡住。
        scheduleHomePhotoNewFileQuery()
        scheduleMediaCompletionFallback(isPhoto: true)
        mediaActionToastMessage = L10n.t("眼镜开始拍照，请从相册中导入", "Photo captured. \nPlease import it from your gallery.")
        print("\(logTag) takephoto0 sent, wait PHOTO_TAKING→STANDBY")
    }

    func toggleVideoRecordingFromHome() {
        guard !isVideoStarting else { return }
        if deviceRuntimeStatus == .videoRecording || isVideoRecording {
            stopVideoRecordingFromHome()
        } else {
            startVideoRecordingFromHome()
        }
    }

    private func startVideoRecordingFromHome() {
        guard !isBatteryTooLowForMedia else {
            mediaActionAlertMessage = lowBatteryMediaMessage
            return
        }
        guard ensureMediaActionAllowed(busy: isVideoStarting || isVideoStopping || videoCompleted) else { return }
        guard isDeviceRuntimeIdle else {
            mediaActionAlertMessage = deviceRuntimeStatus.busyMessage
            return
        }
        homePhotoNewFileQueryWorkItem?.cancel()
        homePhotoNewFileQueryWorkItem = nil
        if deviceGeneration == .gen1G5K61 {
            routineRefreshWorkItem?.cancel()
            routineRefreshWorkItem = nil
            deferredBatteryQuery = true
            deferredPendingImportQuery = true
        }
        guard startVideo() else {
            scheduleDeferredRoutineRetry(after: 1)
            mediaActionAlertMessage = L10n.t("发送开始录像命令失败，请重试", "Failed to start video. Try again.")
            return
        }
        // A queued START can be silently rejected during a call. Wait for actual
        // recording evidence before showing Stop Video or a started message.
        isVideoStarting = true
        isVideoRecording = false
        isVideoStopping = false
        // Recording duration is configured on the glasses. Only the device's
        // recording -> standby reports complete this capture; no timed STOP.
        homeVideoCapture.startSent(at: ProcessInfo.processInfo.systemUptime)
        scheduleHomeVideoStartConfirmation()
        logVideoCapture("start-sent", detail: "durationOwner=device automaticStopCommand=false minimumManualStopDuration=3s")
    }

    private func stopVideoRecordingFromHome() {
        guard ensureMediaActionAllowed(
            busy: isVideoStopping,
            allowedRuntimeStatuses: [.videoRecording],
            requiresAvailableDevice: false
        ) else { return }
        let remaining = homeVideoCapture.stopDelayRemaining(at: ProcessInfo.processInfo.systemUptime)
        guard remaining == 0 else {
            let seconds = Int(ceil(remaining))
            mediaActionToastMessage = L10n.t("录像至少需要 3 秒，请再等 \(seconds) 秒后点击结束录像", "Record for at least 3 seconds. Wait \(seconds) more second(s), then tap Stop Video.")
            logVideoCapture("stop-blocked", detail: "reason=minimum_duration remaining=\(String(format: "%.3f", remaining))s")
            return
        }
        isVideoStopping = true
        guard stopVideo() else {
            isVideoStopping = false
            mediaActionAlertMessage = L10n.t("发送停止录像命令失败，请重试", "Failed to stop video. Try again.")
            return
        }
        homeVideoCapture.stopSent()
        // Missing acknowledgements trigger a status query, never a fabricated success.
        scheduleMediaCompletionFallback(isPhoto: false)
        logVideoCapture("stop-sent", detail: "awaiting=device_standby")
    }

    private func ensureMediaActionAllowed(
        busy: Bool,
        allowedRuntimeStatuses: Set<AstraA1BleProtocol.DeviceRuntimeStatus> = [],
        requiresAvailableDevice: Bool = true
    ) -> Bool {
        guard requiresAvailableDevice ? ensureDeviceAvailable(for: "home-media-action") : isReady else {
            mediaActionAlertMessage = L10n.t("设备未连接", "Device not connected")
            return false
        }
        if deviceGeneration == .gen1G5K61, let targetID = connectedPeripheral?.identifier,
           gen1HotspotCleanup.isPending(targetID) {
            mediaActionAlertMessage = L10n.t("眼镜热点关闭尚未确认，暂不能拍照或录像，请稍后重试。若持续无法恢复，请重启眼镜。", "Hotspot shutdown is not yet confirmed. Wait before taking photos or videos. Restart the glasses if this persists.")
            DebugLogStore.logBLEEvent("Home media action blocked during hotspot cleanup", detail: "target=\(targetID) commandNotSent=true")
            return false
        }
        if deviceRuntimeStatus == .unknown {
            // Android 将 UNKNOWN 与 STANDBY 都视为空闲。这里保留补查，但不再阻断动作。
            forceQueryDeviceStatus(reason: "media-action-unknown")
        }
        guard isDeviceRuntimeIdle || allowedRuntimeStatuses.contains(deviceRuntimeStatus) else {
            mediaActionAlertMessage = deviceRuntimeStatus.busyMessage
            return false
        }
        guard !busy else { return false }
        return true
    }

    /// 蓝牙一上报状态就进这里：先记 previous，再改 current，再看跳变。
    private func applyDeviceRuntimeStatus(
        _ status: AstraA1BleProtocol.DeviceRuntimeStatus,
        source: String,
        receivedFromDevice: Bool = false,
        allowsPhotoCompletion: Bool = true,
        allowsVideoCompletion: Bool = true
    ) {
        if receivedFromDevice {
            deviceRuntimeStatusReportSequence += 1
            lastReportedDeviceRuntimeStatus = status
        }
        let previous = deviceRuntimeStatus
        previousDeviceRuntimeStatus = previous
        deviceRuntimeStatus = status
        print("[device_status] \(status.logDescription) source=\(source) previous=\(previous.name)(\(previous.rawValue))")
        if status != .unknown {
            cancelDeviceStatusSyncRetry()
        }
        handleDeviceRuntimeStatusTransition(from: previous, to: status,
                                            allowsPhotoCompletion: receivedFromDevice && allowsPhotoCompletion,
                                            allowsVideoCompletion: receivedFromDevice && allowsVideoCompletion)
        if receivedFromDevice, deviceGeneration == .gen1G5K61, status == .standby,
           deferredBatteryQuery || deferredPendingImportQuery {
            scheduleDeferredRoutineRetry(after: 0.6)
        }
    }

    /// 每次状态变化都看上次状态：拍照/录像完成只认这里的跳变。
    private func handleDeviceRuntimeStatusTransition(
        from previous: AstraA1BleProtocol.DeviceRuntimeStatus,
        to current: AstraA1BleProtocol.DeviceRuntimeStatus,
        allowsPhotoCompletion: Bool = true,
        allowsVideoCompletion: Bool = true
    ) {
        if current == .photoTaking {
            homePhotoObservedTaking = true
            isTakingPhoto = true
        }
        if isTakingPhoto {
            logPhotoCapture("device-status", detail: "previous=\(previous.name) current=\(current.name)")
        }
        let wasVideoStarting = isVideoStarting
        let recordingStartedAt = homeVideoCapture.startedAt
        let receivedAt = ProcessInfo.processInfo.systemUptime
        let videoFinished = homeVideoCapture.receive(
            current, at: receivedAt, allowsCompletion: allowsVideoCompletion
        )
        isVideoStarting = homeVideoCapture.isStartPending
        if !isVideoStarting { cancelHomeVideoStartConfirmation() }
        isVideoRecording = current == .videoRecording
            || (current == .unknown && homeVideoCapture.hasConfirmedRecording)
        isVideoStopping = homeVideoCapture.isStopPending
        if wasVideoStarting, current == .videoRecording {
            mediaActionToastMessage = L10n.t("眼镜开始录像，请从相册中导入", "Recording has started. \nPlease import the video from your gallery.")
        } else if wasVideoStarting, !isVideoStarting, !isVideoRecording {
            mediaActionToastMessage = current.busyMessage
        }
        if current == .videoRecording || previous == .videoRecording || videoFinished {
            logVideoCapture("device-status", detail: "previous=\(previous.name) current=\(current.name) completionAllowed=\(allowsVideoCompletion)")
        }

        if allowsPhotoCompletion, isTakingPhoto, homePhotoObservedTaking, current == .standby {
            finishPhotoCaptureSuccess(evidence: "device_photo_taking_then_standby")
        }
        if videoFinished {
            if let recordingStartedAt {
                logVideoCapture("device-ended", detail: "elapsedSeconds=\(max(0, receivedAt - recordingStartedAt)) knownDeviceLimitSeconds=\(settingsRecordDurationSeconds.map { String($0) } ?? "unknown") wearDetectionEnabled=\(settingsWearDetectionEnabled.map { String($0) } ?? "unknown") standby_is_not_file_saved_confirmation")
            }
            finishVideoCaptureSuccess()
        }
        // 识图传图：末包可能丢，设备已回空闲 → 通知拼包层用已收数据收尾。
        if previous == .aiVisionOperating, current == .standby {
            print("\(logTag) AI vision device idle (AI_VISION_OPERATING→STANDBY)")
            aiVisionDeviceIdleHandler?()
        }
    }

    private func finishPhotoCaptureSuccess(evidence: String) {
        guard isTakingPhoto else { return }
        if let id = homePhotoAttemptID { PhotoCaptureWatermarkStore.shared.confirm(id: id) }
        logPhotoCapture("completed", detail: "confirmed=true evidence=\(evidence)")
        cancelMediaCompletionFallback()
        isTakingPhoto = false
        if deviceRuntimeStatus == .photoTaking {
            // 该批固件只回 PHOTO_TAKING，不回完成后的 STANDBY；避免陈旧状态阻断后续录像。
            previousDeviceRuntimeStatus = .photoTaking
            deviceRuntimeStatus = .unknown
            resetDeviceStatusQueryGate(reason: "photo-completion-without-standby")
        }
        showPhotoCompletedFeedback()
        print("\(logTag) takephoto completed runtime=\(deviceRuntimeStatus.name)")
    }

    private func finishVideoCaptureSuccess() {
        cancelMediaCompletionFallback()
        isVideoStopping = false
        isVideoRecording = false
        homeVideoCapture.reset()
        showVideoCompletedFeedback()
        mediaActionToastMessage = L10n.t("眼镜结束录像，请从相册中导入", "Recording stopped. \nPlease import the video from your gallery.")
        scheduleHomePhotoNewFileQuery()
        logVideoCapture("completed", detail: "confirmed=device_standby")
    }

    private func handleActionResponse(_ response: AstraA1BleProtocol.DeviceActionResponse) {
        let startRejected = response.action == .startVideo && response.result != .accepted
        if startRejected, response.currentStatus != .videoRecording {
            homeVideoCapture.reset()
            isVideoStarting = false
            cancelHomeVideoStartConfirmation()
            cancelMediaCompletionFallback()
        }
        let stopRejected = response.action == .stopVideo && response.result != .accepted
        if stopRejected {
            homeVideoCapture.stopRejectedOrUnconfirmed()
            cancelMediaCompletionFallback()
        }
        if response.action == .startVideo || response.action == .stopVideo {
            logVideoCapture("action-response", detail: "action=\(response.action.rawValue) result=\(response.rawResult) status=\(response.currentStatus.name)")
        }
        // actionrsp0 里的 current_status 也走同一套全局状态更新。
        if response.action == .takePhoto {
            logPhotoCapture("action-response", detail: "result=\(response.rawResult) status=\(response.currentStatus.name)")
        }
        applyDeviceRuntimeStatus(response.currentStatus, source: "actionrsp0", receivedFromDevice: true,
                                 allowsPhotoCompletion: response.action != .takePhoto || response.result == .accepted,
                                 allowsVideoCompletion: !stopRejected && !startRejected)

        switch response.action {
        case .takePhoto:
            if response.result != .accepted, let id = homePhotoAttemptID {
                PhotoCaptureWatermarkStore.shared.cancel(id: id)
            }
            switch response.result {
            case .accepted:
                print("\(logTag) takephoto ACCEPTED status=\(response.currentStatus.name)")
                logPhotoCapture("accepted", detail: "deviceAccepted=true completionNotImplied=true")
                if isTakingPhoto { scheduleMediaCompletionFallback(isPhoto: true) }
            case .busy:
                isTakingPhoto = false
                cancelMediaCompletionFallback()
                mediaActionAlertMessage = response.currentStatus.busyMessage
            case .invalidState:
                isTakingPhoto = false
                cancelMediaCompletionFallback()
                mediaActionAlertMessage = L10n.t("当前状态不允许拍照", "Can't take photo in current state")
            case .failed:
                isTakingPhoto = false
                cancelMediaCompletionFallback()
                mediaActionAlertMessage = L10n.t("拍照失败，请重试", "Photo failed. Try again.")
            }

        case .startVideo:
            switch response.result {
            case .accepted:
                print("\(logTag) startvideo ACCEPTED status=\(response.currentStatus.name)")
                cancelMediaCompletionFallback()
            case .busy:
                mediaActionAlertMessage = response.currentStatus.busyMessage
            case .invalidState:
                mediaActionAlertMessage = L10n.t("当前状态不允许开始录像", "Can't start video in current state")
            case .failed:
                mediaActionAlertMessage = L10n.t("开始录像失败，请重试", "Failed to start video. Try again.")
            }

        case .stopVideo:
            switch response.result {
            case .accepted:
                print("\(logTag) stopvideo ACCEPTED status=\(response.currentStatus.name)")
                if response.currentStatus != .standby {
                    forceQueryDeviceStatus(reason: "video-stop-accepted-awaiting-standby")
                    scheduleMediaCompletionFallback(isPhoto: false)
                }
            case .busy:
                isVideoStopping = false
                cancelMediaCompletionFallback()
                mediaActionAlertMessage = response.currentStatus.busyMessage
            case .invalidState:
                isVideoStopping = false
                cancelMediaCompletionFallback()
                mediaActionAlertMessage = L10n.t("当前状态不允许停止录像", "Can't stop video in current state")
            case .failed:
                isVideoStopping = false
                cancelMediaCompletionFallback()
                mediaActionAlertMessage = L10n.t("设备未接受停止录像，请稍后重试", "The device did not accept stopping recording. Try again shortly.") + " (\(response.rawResult))"
            }

        case .startFirmwareUpgrade:
            // Android 在 OPENING_WIFI 阶段收到 BUSY / INVALID_STATE / FAILED 会立即终止，不等 wificonfig 超时。
            guard response.result != .accepted,
                  isFirmwareUpgradeFlowBusy,
                  let continuation = wifiConfigContinuation else {
                print("\(logTag) firmware upgrade action result=\(response.result.rawValue) status=\(response.currentStatus.name)")
                break
            }
            wifiConfigContinuation = nil
            continuation.resume(throwing: ImportBLEError.failed(response.currentStatus.busyMessage))

        default:
            print("\(logTag) actionrsp0 ignored action=\(response.action.rawValue) result=\(response.result.rawValue)")
        }
    }

    private var homeVideoStartConfirmationWorkItem: DispatchWorkItem?
    private var homeVideoStartConfirmationID: UUID?

    private func scheduleHomeVideoStartConfirmation(didQueryStatus: Bool = false) {
        cancelHomeVideoStartConfirmation()
        let requestID = UUID()
        homeVideoStartConfirmationID = requestID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.homeVideoStartConfirmationID == requestID,
                  self.isReady, self.isVideoStarting else { return }
            if !didQueryStatus {
                self.logVideoCapture("start-awaiting-status", detail: "elapsed=4s action=query_status recordingConfirmed=false")
                self.forceQueryDeviceStatus(reason: "video-start-awaiting-confirmation")
                self.scheduleHomeVideoStartConfirmation(didQueryStatus: true)
                return
            }
            guard self.homeVideoCapture.expireUnconfirmedStart() else { return }
            self.isVideoStarting = false
            self.cancelHomeVideoStartConfirmation()
            self.logVideoCapture("start-unconfirmed", detail: "elapsed=8s recordingConfirmed=false noAutomaticStop=true noAutomaticResend=true")
            self.mediaActionAlertMessage = L10n.t(
                "未确认眼镜开始录像，请检查是否正在通话或设备正忙，稍后重试。",
                "Glasses have not confirmed recording started. Check for an ongoing call or a busy device, then try again."
            )
            self.scheduleDeferredRoutineRetry(after: 0.6)
        }
        homeVideoStartConfirmationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func cancelHomeVideoStartConfirmation() {
        homeVideoStartConfirmationWorkItem?.cancel()
        homeVideoStartConfirmationWorkItem = nil
        homeVideoStartConfirmationID = nil
    }

    private var mediaCompletionFallbackWorkItem: DispatchWorkItem?

    /// Query missing completion evidence once; a timeout unlocks retry without
    /// claiming success or automatically repeating a capture command.
    private func scheduleMediaCompletionFallback(isPhoto: Bool, didQueryVideoStatus: Bool = false, didQueryPhotoStatus: Bool = false) {
        cancelMediaCompletionFallback()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if isPhoto, self.isTakingPhoto || self.deviceRuntimeStatus == .photoTaking {
                if !didQueryPhotoStatus {
                    self.logPhotoCapture("awaiting-confirmation", detail: "elapsed=4s action=query_status_and_files completion=false")
                    self.forceQueryDeviceStatus(reason: "photo-fallback")
                    self.queryPendingImportFiles()
                    self.scheduleMediaCompletionFallback(isPhoto: true, didQueryPhotoStatus: true)
                    return
                }
                self.logPhotoCapture("unconfirmed", detail: "elapsed=8s completion=false noAutomaticResend=true")
                self.isTakingPhoto = false
                self.mediaActionAlertMessage = L10n.t("未确认拍照完成，请重试", "Photo completion not confirmed. Please try again.")
            } else if !isPhoto, self.isVideoStopping || self.deviceRuntimeStatus == .videoRecording {
                if !didQueryVideoStatus {
                    // Give the status reply time to arrive before unlocking Stop.
                    // Otherwise a successful stop with a missing ACK asks for a second tap.
                    self.logVideoCapture("stop-awaiting-status", detail: "elapsed=4s action=query_status stopPending=\(self.isVideoStopping)")
                    self.forceQueryDeviceStatus(reason: "video-stop-fallback")
                    self.scheduleMediaCompletionFallback(isPhoto: false, didQueryVideoStatus: true)
                    return
                }
                self.homeVideoCapture.stopRejectedOrUnconfirmed()
                self.isVideoStopping = false
                self.logVideoCapture("stop-unconfirmed", detail: "elapsed=8s action=query_status completion=false")
                self.forceQueryDeviceStatus(reason: "video-stop-fallback")
                self.mediaActionToastMessage = L10n.t("尚未确认录像已停止，正在查询设备状态，请稍后重试", "Recording stop is not confirmed. Checking device status; please try again shortly.")
            }
        }
        mediaCompletionFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func cancelMediaCompletionFallback() {
        mediaCompletionFallbackWorkItem?.cancel()
        mediaCompletionFallbackWorkItem = nil
    }

    private func scheduleHomePhotoNewFileQuery() {
        homePhotoNewFileQueryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isReady else { return }
            guard !self.isVideoStarting, !self.isVideoRecording, !self.isVideoStopping,
                  self.deviceRuntimeStatus != .videoRecording else {
                self.logVideoCapture("skip-file-query", detail: "reason=recording")
                return
            }
            self.queryPendingImportFiles()
            print("\(self.logTag) query hasnewfile after home photo")
        }
        homePhotoNewFileQueryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func logVideoCapture(_ event: String, detail: String = "") {
        DebugLogStore.logBLEEvent("Video capture \(event)", detail:
            "target=\(deviceBluetoothIdentifier ?? "none") generation=\(deviceGeneration) gattState=\(connectStateDescription(connectionState)) peripheralState=\(connectedPeripheral.map { peripheralStateDescription($0.state) } ?? "none") runtime=\(deviceRuntimeStatus.name) starting=\(isVideoStarting) recording=\(isVideoRecording) stopping=\(isVideoStopping) completed=\(videoCompleted) \(detail)")
    }

    private func forceQueryDeviceStatus(reason: String) {
        let sent = sendCommand(AstraA1BleProtocol.buildGetDeviceStatusCommand())
        print("[device_status] getdevstat force reason=\(reason) sent=\(sent)")
    }

    /// 设备不补结束状态时，按业务已完成事实清除陈旧 busy；UNKNOWN 仍按 Android 视为空闲。
    private func finishRuntimeOperationIfNeeded(
        expected: AstraA1BleProtocol.DeviceRuntimeStatus,
        fallback: AstraA1BleProtocol.DeviceRuntimeStatus,
        reason: String
    ) {
        guard deviceRuntimeStatus == expected else { return }
        applyDeviceRuntimeStatus(fallback, source: reason)
        resetDeviceStatusQueryGate(reason: reason)
    }

    /// Android FileImportManager 在完成、取消、失败时都把设备状态本地重置为 STANDBY。
    func syncDeviceStatusAfterImport(reason: String = "after-import") {
        if deviceRuntimeStatus == .fileImporting || deviceRuntimeStatus == .unknown {
            applyDeviceRuntimeStatus(.standby, source: reason)
            resetDeviceStatusQueryGate(reason: reason)
        }
        if isReady {
            forceQueryDeviceStatus(reason: reason)
        }
    }

    /// OTA 完成或失败后清除旧 FIRMWARE_UPGRADING；设备重启断线时连接状态也会置 UNKNOWN。
    func finishFirmwareUpgradeRuntime(reason: String) {
        finishRuntimeOperationIfNeeded(
            expected: .firmwareUpgrading,
            fallback: .unknown,
            reason: reason
        )
    }

    /// Android 从固件包下载前 markBusy；这里同步暂停例行电量和待导入查询。
    func beginFirmwareUpgradeFlow(gen1LoaderRecovery: Gen1BluetoothOtaRecoveryStore.Record? = nil) {
        // A submitted Gen1 loader may expose only RCSP, without the ordinary
        // control service. Its bound recovery record still owns the OTA flow,
        // including background-query suppression and post-upgrade reconnection.
        let ownsLoaderRecovery = gen1LoaderRecovery.map { record in
            record.permitsLoaderRecovery(savedID: savedPeripheralID(), accountID: gen1ImportAccount(for: record.targetID))
                && (connectedPeripheral == nil || connectedPeripheral?.identifier == record.targetID)
        } ?? false
        guard ownsLoaderRecovery || ensureDeviceAvailable(for: "beginFirmwareUpgradeFlow") else { return }
        guard !isFirmwareUpgradeFlowBusy else { return }
        isFirmwareUpgradeFlowBusy = true
        deviceVersionQueryGate.cancelPendingQuery()
        if deviceGeneration == .gen2, let id = connectedPeripheral?.identifier {
            gen2OtaRecovery.begin(targetID: id)
            gen2OtaLastProgressAt = nil
        } else {
            gen2OtaRecovery.finish()
        }
        routineRefreshWorkItem?.cancel()
        routineRefreshWorkItem = nil
        cancelInitialDeviceInfoQuery(reason: "firmware-upgrade")
        cancelAboutDeviceInfoQuery()
        isQueryingAboutDeviceInfo = false
        cancelVersionsAndStorageQuery()
        stopBatteryPolling()
        print("\(logTag) firmware upgrade flow busy=true")
    }

    /// 无论成功、失败或取消都恢复 Android 同等的例行查询。
    func endFirmwareUpgradeFlow(reason: String, preserveRuntimeStatus: Bool = false) {
        gen1OTAVerificationPeripheralID = nil
        gen2OtaRecovery.finish()
        guard isFirmwareUpgradeFlowBusy else {
            if !preserveRuntimeStatus { finishFirmwareUpgradeRuntime(reason: reason) }
            return
        }
        isFirmwareUpgradeFlowBusy = false
        if !preserveRuntimeStatus { finishFirmwareUpgradeRuntime(reason: reason) }
        print("\(logTag) firmware upgrade flow busy=false reason=\(reason)")
        guard isReady else { return }
        startBatteryPolling()
        scheduleRoutineDeviceRefresh()
    }

    /// Cancellation is allowed only for an accepted preparation owned by this flow,
    /// before either otaupload command has been queued. Never infer ownership from busy=6.
    func canCancelGen2OtaPreparation(for targetID: UUID) -> Bool {
        isFirmwareUpgradeFlowBusy && gen2OtaRecovery.canCancelPreparation(for: targetID)
    }

    @discardableResult
    func cancelGen2OtaPreparation(for targetID: UUID) -> Bool {
        guard canCancelGen2OtaPreparation(for: targetID), isReady,
              deviceGeneration == .gen2, connectedPeripheral?.identifier == targetID else { return false }
        let sent = sendCommand(AstraA1BleProtocol.buildOtaCancelCommand())
        wifiLog("退出本次 OTA 准备", detail: "peripheral=\(targetID) command=otacancel0 queued=\(sent); queued does not confirm device exit", direction: .sent)
        return sent
    }

    func hasSubmittedGen2Ota(for targetID: UUID) -> Bool {
        gen2OtaRecovery.targetID == targetID && gen2OtaRecovery.upgradeSubmitted
    }

    func hasCompletedGen2Ota(for targetID: UUID) -> Bool {
        gen2OtaRecovery.targetID == targetID && gen2OtaRecovery.upgradeCompleted
    }

    func hasGen2OtaProgress(for targetID: UUID, since time: TimeInterval) -> Bool {
        gen2OtaRecovery.targetID == targetID && (gen2OtaLastProgressAt ?? -Double.infinity) >= time
    }

    @discardableResult
    func confirmGen2OtaFailure(for targetID: UUID) -> Bool {
        isFirmwareUpgradeFlowBusy && gen2OtaRecovery.confirmFailure(for: targetID)
    }

    func canCancelFailedGen2Ota(for targetID: UUID) -> Bool {
        isFirmwareUpgradeFlowBusy && gen2OtaRecovery.canCancelFailedAttempt(for: targetID)
    }

    @discardableResult
    func cancelFailedGen2Ota(for targetID: UUID) -> Bool {
        guard canCancelFailedGen2Ota(for: targetID), isReady,
              savedPeripheralID() == targetID, connectedPeripheral?.identifier == targetID,
              deviceGeneration == .gen2 else { return false }
        let sent = sendCommand(AstraA1BleProtocol.buildOtaCancelCommand())
        wifiLog("升级：失败后退出 OTA", detail: "target=\(targetID) command=otacancel0 queued=\(sent); wait for fresh device status", direction: .sent)
        return sent
    }

    /// Dedicated query bypasses routine-refresh suppression during this OTA flow.
    @discardableResult
    func queryGen2OtaVersion(for targetID: UUID, firmware: Bool) -> Bool {
        guard isFirmwareUpgradeFlowBusy, gen2OtaRecovery.targetID == targetID,
              isReady, savedPeripheralID() == targetID,
              connectedPeripheral?.identifier == targetID, deviceGeneration == .gen2 else { return false }
        let sent = sendCommand(AstraA1BleProtocol.buildGetDevInfoCommand(type: firmware ? .version6350 : .version2800))
        wifiLog("升级：查询本次升级版本", detail: "target=\(targetID) key=\(firmware ? "ver63" : "ver28") queued=\(sent)", direction: .sent)
        return sent
    }

    func queryGen2OtaRuntimeStatus(for targetID: UUID) {
        guard isReady, deviceGeneration == .gen2,
              connectedPeripheral?.identifier == targetID else { return }
        forceQueryDeviceStatus(reason: "ota-preparation-cleanup")
    }

    private func showPhotoCompletedFeedback() {
        photoCompleted = true
        photoCompletedResetTask?.cancel()
        photoCompletedResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            photoCompleted = false
        }
    }

    private func showVideoCompletedFeedback() {
        videoCompleted = true
        videoCompletedResetTask?.cancel()
        videoCompletedResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            videoCompleted = false
        }
    }

    private func resetHomeMediaCaptureState() {
        homeVideoCapture.reset()
        cancelHomeVideoStartConfirmation()
        homePhotoAttemptID = nil
        homePhotoObservedTaking = false
        homePhotoBaselineCount = 0
        cancelMediaCompletionFallback()
        photoCompletedResetTask?.cancel()
        videoCompletedResetTask?.cancel()
        homePhotoNewFileQueryWorkItem?.cancel()
        homePhotoNewFileQueryWorkItem = nil
        isTakingPhoto = false
        photoCompleted = false
        isVideoStarting = false
        isVideoRecording = false
        isVideoStopping = false
        videoCompleted = false
        previousDeviceRuntimeStatus = .unknown
        deviceRuntimeStatus = .unknown
        mediaActionAlertMessage = nil
        mediaActionToastMessage = nil
    }

    /// Notification 就绪后查询一次设备状态（对齐安卓 syncDeviceStateAfterConnected）；后续靠 devstatus0。
    private let isGetDeviceStatusQueryEnabled = true

    private func syncDeviceRuntimeStatusAfterConnected() {
        guard isGetDeviceStatusQueryEnabled else {
            print("[device_status] getdevstat skipped (temporarily disabled)")
            cancelDeviceStatusSyncRetry()
            return
        }
        guard writeCharacteristic != nil else {
            print("[device_status] getdevstat skipped: write characteristic missing")
            return
        }
        // 必须等协议 notify 订阅成功，否则回包收不到（电池 notify 不算）。
        let protocolNotifying = isProtocolNotificationEnabled
            || (notifyCharacteristic?.isNotifying == true)
        guard protocolNotifying else {
            print("[device_status] getdevstat deferred: protocol notify not enabled")
            scheduleDeviceStatusSyncRetry()
            return
        }

        // 已有权威状态则不再刷；仅 UNKNOWN 时补一枪（避免进首页狂刷）。
        guard deviceRuntimeStatus == .unknown else {
            print("[device_status] getdevstat skipped: already \(deviceRuntimeStatus.logDescription)")
            cancelDeviceStatusSyncRetry()
            return
        }

        // 同一连接只主动发一轮，避免 ready / notify / recover 多入口叠发把眼镜打挂。
        if hasRequestedDeviceStatusThisConnection {
            print("[device_status] getdevstat skipped: already requested this connection")
            return
        }
        hasRequestedDeviceStatusThisConnection = true

        let sent = sendCommand(AstraA1BleProtocol.buildGetDeviceStatusCommand())
        print("[device_status] getdevstat sent=\(sent) ready=\(isReady) notify=\(protocolNotifying) current=\(deviceRuntimeStatus.logDescription) attempt=\(deviceStatusSyncAttempt)")
        scheduleDeviceStatusSyncRetry()
    }

    private func scheduleDeviceStatusSyncRetry() {
        deviceStatusSyncRetryWorkItem?.cancel()
        guard deviceRuntimeStatus == .unknown else {
            deviceStatusSyncAttempt = 0
            return
        }
        guard deviceStatusSyncAttempt < maxDeviceStatusSyncAttempts else {
            print("[device_status] getdevstat retry exhausted, still UNKNOWN")
            return
        }
        deviceStatusSyncAttempt += 1
        let delay = 0.8 * Double(deviceStatusSyncAttempt)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.deviceRuntimeStatus == .unknown else { return }
            // 重试允许再发一枪。
            self.hasRequestedDeviceStatusThisConnection = false
            print("[device_status] getdevstat retry #\(self.deviceStatusSyncAttempt)")
            self.syncDeviceRuntimeStatusAfterConnected()
        }
        deviceStatusSyncRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelDeviceStatusSyncRetry() {
        deviceStatusSyncRetryWorkItem?.cancel()
        deviceStatusSyncRetryWorkItem = nil
        deviceStatusSyncAttempt = 0
    }

    private func resetDeviceStatusQueryGate(reason: String) {
        cancelDeviceStatusSyncRetry()
        hasRequestedDeviceStatusThisConnection = false
        print("[device_status] gate reset reason=\(reason)")
    }

    func deleteImportedFiles(_ fileNames: [String], timeout: TimeInterval = 10) async throws {
        guard ensureDeviceAvailable(for: "deleteImportedFiles") else { throw ImportBLEError.notReady }
        guard !fileNames.isEmpty else { return }

        // 按实际写 MTU 切批：固定 200 在 iOS 常超 maxWrite → 包被截断 → 眼镜回拒绝。
        let maxWrite = connectedPeripheral.map {
            max(
                $0.maximumWriteValueLength(for: .withResponse),
                $0.maximumWriteValueLength(for: .withoutResponse)
            )
        } ?? 182
        let maxPayload = max(32, min(200, maxWrite - 12))
        var remaining = fileNames
        print("\(logTag) deletefile total=\(remaining.count) maxWrite=\(maxWrite) maxPayload=\(maxPayload)")

        while !remaining.isEmpty {
            guard ensureDeviceAvailable(for: "deleteImportedFiles") else { throw ImportBLEError.notReady }
            let batches = AstraA1BleProtocol.splitDeleteFileBatches(remaining, maxPayloadBytes: maxPayload)
            guard let batch = batches.first else { break }

            let payloadBytes = AstraA1BleProtocol.deleteFilePayloadByteCount(fileNames: batch)
            print("\(logTag) deletefile batch count=\(batch.count) payload≈\(payloadBytes)B names=\(batch)")

            var batchOK = false
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    let deleted = try await waitStatusResponse(
                        command: "deletefile",
                        timeout: timeout
                    ) {
                        self.sendDeleteFileCommand(fileNames: batch)
                    }
                    if deleted {
                        batchOK = true
                        print("\(logTag) deletefile ok attempt=\(attempt) count=\(batch.count)")
                        break
                    }
                    lastError = ImportBLEError.failed(L10n.t("眼镜拒绝删除已导入文件", "Glasses refused to delete imported files"))
                    print("\(logTag) deletefile rejected attempt=\(attempt) count=\(batch.count)")
                } catch {
                    lastError = error
                    print("\(logTag) deletefile attempt=\(attempt) err=\(error.localizedDescription)")
                }
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }

            // 批量仍失败：逐个删（录音场景更稳）。
            if !batchOK, batch.count > 1 {
                print("\(logTag) deletefile fallback to single-file deletes count=\(batch.count)")
                var singleFailed: [String] = []
                for name in batch {
                    do {
                        let ok = try await waitStatusResponse(command: "deletefile", timeout: timeout) {
                            self.sendDeleteFileCommand(fileNames: [name])
                        }
                        if ok {
                            print("\(logTag) deletefile single ok name=\(name)")
                        } else {
                            singleFailed.append(name)
                            print("\(logTag) deletefile single rejected name=\(name)")
                        }
                    } catch {
                        singleFailed.append(name)
                        print("\(logTag) deletefile single err name=\(name) \(error.localizedDescription)")
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if singleFailed.isEmpty {
                    batchOK = true
                } else {
                    remaining = singleFailed + Array(batches.dropFirst().joined())
                    throw lastError ?? ImportBLEError.failed(L10n.t("眼镜拒绝删除已导入文件", "Glasses refused to delete imported files"))
                }
            }

            guard batchOK else {
                throw lastError ?? ImportBLEError.failed(L10n.t("眼镜拒绝删除已导入文件", "Glasses refused to delete imported files"))
            }

            remaining = Array(batches.dropFirst().joined())
            if !remaining.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// deletefile 优先 withResponse，避免 withoutResponse 大包被静默截断。
    @discardableResult
    private func sendDeleteFileCommand(fileNames: [String]) -> Bool {
        guard ensureDeviceAvailable(for: "deletefile") else { return false }
        let data = AstraA1BleProtocol.buildDeleteFileCommand(fileNames: fileNames)
        guard case .ready = connectionState,
              let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic else {
            print("\(logTag) sendDeleteFileCommand failed: not ready")
            return false
        }
        let maxWrite = peripheral.maximumWriteValueLength(for: .withResponse)
        if data.count > maxWrite {
            print("\(logTag) sendDeleteFileCommand oversized bytes=\(data.count) maxWrite=\(maxWrite)")
            return false
        }
        if characteristic.properties.contains(.write) {
            guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            print("[BLE] Packet exceeds negotiated write length")
            return false
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
            print("\(logTag) deletefile \(data.count) bytes withResponse")
            DebugLogStore.logBLESent(data)
            return true
        }
        return sendCommand(data)
    }

    func closeWifi(timeout: TimeInterval = 5) async throws {
        guard isReady else {
            wifiLog("无法关闭热点：BLE 未就绪", direction: .received)
            throw ImportBLEError.notReady
        }
        // 设备回包命令头为 closewifi（安卓同）；兼容旧固件 closewifi0。
        defer { lastWifiCloseAt = Date() }
        wifiLog(
            "发送 closewifi",
            detail: "timeout=\(String(format: "%.1f", timeout))s",
            direction: .sent
        )
        do {
            let accepted = try await waitStatusResponse(
                command: "closewifi",
                aliases: ["closewifi0"],
                timeout: timeout
            ) {
                self.sendCommand(AstraA1BleProtocol.buildCloseWifiCommand())
            }
            guard accepted else {
                throw ImportBLEError.failed(L10n.t("眼镜拒绝关闭热点", "Glasses rejected hotspot shutdown"))
            }
            wifiLog("眼镜热点关闭成功", direction: .received)
        } catch {
            wifiLog("眼镜热点关闭失败", detail: "error=\(error.localizedDescription)", direction: .received)
            throw error
        }
    }

    /// 眼镜关热点后需要时间释放 AP，紧接着 toopenwifi 容易起不来。
    /// 对齐安卓 `WIFI_REOPEN_DELAY_MS = 1000`。
    private func waitWifiReopenCooldown() async {
        guard let last = lastWifiCloseAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed < Self.wifiReopenCooldown else { return }
        let remaining = Self.wifiReopenCooldown - elapsed
        print("\(logTag) wait \(String(format: "%.2f", remaining))s before toopenwifi (wifi reopen cooldown)")
        wifiLog("等待眼镜热点释放", detail: "remaining=\(String(format: "%.2f", remaining))s")
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    private func waitStatusResponse(
        command: String,
        aliases: [String] = [],
        timeout: TimeInterval = 10,
        send: () -> Bool
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            statusContinuationCommand = command
            statusContinuationAliases = Set(aliases).union([command])
            statusContinuation = continuation
            guard send() else {
                statusContinuation = nil
                statusContinuationCommand = nil
                statusContinuationAliases = []
                continuation.resume(throwing: ImportBLEError.sendFailed)
                return
            }
            scheduleImportTimeout(seconds: timeout) { [weak self] in
                guard let self, let cont = self.statusContinuation else { return }
                self.statusContinuation = nil
                self.statusContinuationCommand = nil
                self.statusContinuationAliases = []
                cont.resume(throwing: ImportBLEError.timeout)
            }
        }
    }

    /// 下发媒体指令后等待眼镜推送 hasnewfile(hasNew=true)，表示新文件已生成。
    private func waitForNewMediaFile(timeout: TimeInterval, send: () -> Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            mediaCaptureContinuation = continuation
            guard send() else {
                mediaCaptureContinuation = nil
                continuation.resume(throwing: ImportBLEError.sendFailed)
                return
            }
            scheduleImportTimeout(seconds: timeout) { [weak self] in
                guard let self, let cont = self.mediaCaptureContinuation else { return }
                self.mediaCaptureContinuation = nil
                cont.resume(throwing: ImportBLEError.timeout)
            }
        }
    }

    private func scheduleImportTimeout(seconds: TimeInterval, handler: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: handler)
    }

    /// 通知不足声明长度时尝试读特征。固件可能不支持读，结果必须进入可导出的日志。
    private func requestFullNotifyPayload(for command: String) {
        guard let peripheral = connectedPeripheral, let char = notifyCharacteristic else {
            DebugLogStore.logBLEEvent("notify read skipped", detail: "command=\(command) reason=no-current-characteristic")
            return
        }
        guard !notifyReadInFlight else {
            DebugLogStore.logBLEEvent("notify read already pending", detail: "command=\(command) pending=\(notifyReadCommand ?? "nil") issued=\(notifyReadWasIssued)")
            return
        }
        if notifyReadCommand != command {
            notifyReadCommand = command
            notifyReadAttempts = 0
        }
        guard !notifyReadUnsupported else {
            DebugLogStore.logBLEEvent("notify read unavailable", detail: "command=\(command) reason=firmware-request-not-supported")
            failWaitersOnTruncation(command: command)
            return
        }
        guard notifyReadAttempts < maxNotifyReadAttempts else {
            DebugLogStore.logBLEEvent("notify read exhausted", detail: "command=\(command) attempts=\(notifyReadAttempts)")
            failWaitersOnTruncation(command: command)
            return
        }
        notifyReadInFlight = true
        notifyReadWasIssued = false
        notifyReadRequestID = UUID()
        let requestID = notifyReadRequestID
        notifyReadAttempts += 1
        DebugLogStore.logBLEEvent(
            "notify read scheduled",
            detail: "request=\(requestID) command=\(command) attempt=\(notifyReadAttempts)/\(maxNotifyReadAttempts) delay=\(notifyReadRetryDelay)s peripheral=\(peripheral.identifier)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + notifyReadRetryDelay) { [weak self] in
            guard let self else { return }
            guard self.notifyReadRequestID == requestID,
                  self.connectedPeripheral === peripheral,
                  self.notifyCharacteristic === char else {
                DebugLogStore.logBLEEvent("notify read cancelled", detail: "request=\(requestID) reason=superseded-or-connection-changed")
                return
            }
            guard self.notifyReadInFlight else {
                DebugLogStore.logBLEEvent("notify read cancelled", detail: "request=\(requestID) reason=value-callback-before-read")
                return
            }
            self.notifyReadWasIssued = true
            DebugLogStore.logBLEEvent("notify read issued", detail: "request=\(requestID) command=\(command) characteristic=\(char.uuid)")
            peripheral.readValue(for: char)
        }
    }

    /// 补读无望时立刻让等待方失败，别让调用方干等到超时。
    private func failWaitersOnTruncation(command: String) {
        DebugLogStore.logBLEEvent("incomplete packet recovery ended", detail: "command=\(command) attempts=\(notifyReadAttempts) unsupported=\(notifyReadUnsupported)")
        notifyReadCommand = nil
        if let cont = wifiConfigContinuation {
            wifiConfigContinuation = nil
            cont.resume(throwing: ImportBLEError.truncated)
        }
        if let cont = workPathContinuation {
            workPathContinuation = nil
            cont.resume(throwing: ImportBLEError.failed(
                L10n.t("HTTP 路径读取失败（BLE 数据被截断）", "Failed to read HTTP path (BLE data truncated)")
            ))
        }
        if let cont = algorithmInfoContinuation {
            algorithmInfoContinuation = nil
            cont.resume(throwing: ImportBLEError.truncated)
        }
        if isQueryingAboutDeviceInfo {
            finishAboutDeviceInfoQueryStep()
        }
        if isQueryingDeviceVersionsAndStorage {
            finishVersionsAndStorageQueryStep()
        }
    }

    /// 相册页：刷新待导入文件数（已连接则直接查，否则走重连）。
    func refreshPendingImportFiles() {
        if case .ready = connectionState {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.queryPendingImportFiles()
            }
            return
        }
        // 复用电量刷新的重连路径，连上后会同时查电量与待导入文件
        refreshBatteryLevel()
    }

    /// 开始扫描；发现设备后列入弹窗，由用户手动选择再连接。
    func startPairing(preferredDeviceName: String? = nil) {
        guard let modelName = preferredDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelName.isEmpty else {
            updateState(.failed(L10n.t("请先选择设备型号", "Select a device model first")))
            return
        }
        guard prepareCentralManager(allowAuthorizationRequest: true) else { return }
        homeSelectionTargetID = nil
        gen1OTAVerificationPeripheralID = nil
        pendingBoundSerialNumbers = []
        pendingBatteryRefresh = false
        // 解绑后的 didConnect/didDisconnect 可能延迟抵达。新配对必须先清掉旧链路目标，
        // 否则旧 ready 回调会结束新 session，首次点击便会永久停在“正在配对”。
        let stalePeripheral = connectedPeripheral ?? reconnectPeripheral
        cancelScanTimeout()
        cancelProbeStart()
        cancelManualReconnectScanTimeout()
        cancelConnectWatchdog()
        cancelDiscoverServicesWorkItem()
        cancelAutomaticGATTRecovery(reason: "fresh-pairing-session", resetAttempts: true)
        boundBLEReconnectPolicy.reset()
        cancelManualHardReconnectState(reason: "fresh-pairing-session")
        if let stalePeripheral, stalePeripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(stalePeripheral)
        }
        resetConnectionHandles()
        reconnectPeripheral = nil
        pendingUserPairingPeripheral = nil
        userPairingTargetID = nil
        userPairingRetryCount = 0
        isManualReconnectScan = false
        isManualReconnectConnect = false
        userInitiatedDisconnect = false
        autoReconnectEnabled = false
        hasStartedConnect = false
        isServiceDiscovered = false
        isNotificationEnabled = false
        isProbingService = false
        pendingCharacteristicDiscoveries = 0
        writeCharacteristic = nil
        notifyCharacteristic = nil
        deviceName = nil
        deviceModel = nil
        deviceSN = nil
        resetBatteryDisplayForFreshRead()
        deviceIsCharging = false
        deviceStorage = nil
        deviceVersion2800 = nil
        deviceVersion6350 = nil
        cancelAboutDeviceInfoQuery()
        isQueryingAboutDeviceInfo = false
        cancelVersionsAndStorageQuery()
        pendingImportFileCount = 0
        pendingRecordingImportFileCount = 0
        isAIRecording = false
        isDeviceInfoReady = false
        identityPeripheralID = nil
        loggedPeripheralIDs.removeAll()
        probeCandidates.removeAll()
        probedIDs.removeAll()
        discoveredPairingDevices = []
        discoveredPeripherals = [:]
        isPairingSessionActive = true
        isManualPairingScan = true
        isUserInitiatedPairingConnect = false
        pairingModelNameFilter = modelName

        print("\(logTag) startPairing, central state=\(centralManager.state.rawValue)")
        print("\(logTag) pairing scan filter by device name containing model_name=\(modelName)")

        switch centralManager.state {
        case .poweredOn:
            beginScan()
        case .unauthorized:
            updateState(.bluetoothUnavailable(L10n.t("请在设置中允许蓝牙权限", "Allow Bluetooth in Settings")))
        case .poweredOff:
            updateState(.bluetoothUnavailable(L10n.t("请打开手机蓝牙", "Turn on Bluetooth")))
        case .unsupported:
            updateState(.bluetoothUnavailable(L10n.t("当前设备不支持蓝牙", "Bluetooth not supported")))
        default:
            pendingStart = true
            updateState(.scanning)
        }
    }

    /// 用户在配对弹窗中选择设备后开始连接。
    @discardableResult
    func pairWithDiscoveredDevice(id: UUID) -> Bool {
        guard isPairingSessionActive else { return false }
        guard let peripheral = discoveredPeripherals[id] else {
            print("\(logTag) pairWithDiscoveredDevice missing peripheral \(id.uuidString)")
            return false
        }

        print("\(logTag) user selected pairing device \(peripheral.name ?? id.uuidString)")
        userPairingTargetID = id
        userPairingRetryCount = 0
        stopPairingListProbe()
        isManualPairingScan = false
        isUserInitiatedPairingConnect = true
        connectForUserPairing(to: peripheral)
        return true
    }

    /// 停止配对弹窗的后台探测，避免与用户点「配对」抢连接。
    private func stopPairingListProbe() {
        cancelScanTimeout()
        cancelProbeStart()
        cancelConnectWatchdog()
        cancelDiscoverServicesWorkItem()
        stopScan()
        probeCandidates.removeAll()
        activeProbeRSSI = nil
        isProbingService = false

        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
            connectedPeripheral = nil
            writeCharacteristic = nil
            notifyCharacteristic = nil
            batteryLevelCharacteristic = nil
            isServiceDiscovered = false
            isNotificationEnabled = false
            pendingCharacteristicDiscoveries = 0
            pendingCharacteristicServices.removeAll()
        }

        hasStartedConnect = false
    }

    private func connectForUserPairing(to peripheral: CBPeripheral) {
        cancelScanTimeout()
        cancelProbeStart()
        stopScan()

        userInitiatedDisconnect = false
        autoReconnectEnabled = true
        standingConnectAllowed = true
        savePeripheralID(peripheral.identifier)

        reconnectPeripheral = peripheral
        peripheral.delegate = self
        hasStartedConnect = true
        isProbingService = false
        gattDiscoveryAttempt = 0
        updateState(.connecting)

        if peripheral.state == .connected || peripheral.state == .connecting {
            print("\(logTag) user pairing: reset existing link to trigger system pairing")
            pendingUserPairingPeripheral = peripheral
            connectedPeripheral = peripheral
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        connectedPeripheral = peripheral
        print("\(logTag) user pairing connect \(peripheral.name ?? peripheral.identifier.uuidString)")
        centralManager.connect(peripheral, options: pairingConnectOptions)
        startConnectWatchdog(for: peripheral)
    }

    private var pairingConnectOptions: [String: Any] {
        [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ]
    }

    private func resumePendingUserPairingConnect(_ peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        reconnectPeripheral = peripheral
        peripheral.delegate = self
        hasStartedConnect = true
        isProbingService = false
        gattDiscoveryAttempt = 0
        updateState(.connecting)
        print("\(logTag) user pairing reconnect \(peripheral.name ?? peripheral.identifier.uuidString)")
        centralManager.connect(peripheral, options: pairingConnectOptions)
        startConnectWatchdog(for: peripheral)
    }

    private func retryUserPairingConnect(reason: String) {
        guard isPairingSessionActive, isUserInitiatedPairingConnect else { return }
        guard userPairingRetryCount < maxUserPairingRetries else {
            isUserInitiatedPairingConnect = false
            hasStartedConnect = false
            updateState(.failed(L10n.t("连接失败，请重试", "Connection failed, retry")))
            return
        }
        guard let targetID = userPairingTargetID,
              let peripheral = discoveredPeripherals[targetID] else {
            isUserInitiatedPairingConnect = false
            hasStartedConnect = false
            updateState(.failed(L10n.t("连接失败，请重试", "Connection failed, retry")))
            return
        }

        userPairingRetryCount += 1
        print("\(logTag) retry user pairing (\(userPairingRetryCount)/\(maxUserPairingRetries)): \(reason)")
        cancelConnectWatchdog()
        cancelDiscoverServicesWorkItem()
        if let current = connectedPeripheral, current.identifier != targetID {
            centralManager.cancelPeripheralConnection(current)
        }
        connectedPeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        batteryLevelCharacteristic = nil
        isServiceDiscovered = false
        isNotificationEnabled = false
        pendingCharacteristicDiscoveries = 0
        hasStartedConnect = false
        pendingCharacteristicServices.removeAll()
        gattDiscoveryAttempt = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isUserInitiatedPairingConnect else { return }
            self.connectForUserPairing(to: peripheral)
        }
    }

    private func shouldPauseBackgroundProbe() -> Bool {
        isManualPairingScan && !discoveredPairingDevices.isEmpty
    }

    /// 取消扫描/连接（用户点取消）。
    func cancelPairing() {
        homeSelectionTargetID = nil
        gen1OTAVerificationPeripheralID = nil
        pendingStart = false
        pendingBoundSerialNumbers = []
        cancelManualReconnectScanTimeout()
        isManualReconnectScan = false
        isManualReconnectConnect = false
        isBatteryRefreshMode = false
        pendingBatteryRefresh = false
        userInitiatedDisconnect = true
        autoReconnectEnabled = false
        isPairingSessionActive = false
        isManualPairingScan = false
        isUserInitiatedPairingConnect = false
        pairingModelNameFilter = nil
        userPairingTargetID = nil
        userPairingRetryCount = 0
        pendingUserPairingPeripheral = nil
        standingConnectRecoveryCount = 0
        cancelManualHardReconnectState(reason: "cancel-pairing")
        discoveredPairingDevices = []
        discoveredPeripherals = [:]
        cancelScanTimeout()
        cancelProbeStart()
        stopScan()

        if let peripheral = connectedPeripheral ?? reconnectPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        reconnectPeripheral = nil
        resetConnectionHandles()
        updateState(.idle)
    }

    /// 退出登录时断开 BLE，并清除已保存的设备标识。
    func disconnectAndClearSession(reason: String = #function, file: StaticString = #fileID, line: UInt = #line) {
        connectLog("disconnect and clear session requested",
                   detail: "source=\(reason) file=\(file) line=\(line) \(connectionAvailabilityDiagnosticDetail)")
        homeSelectionRetryPolicies.removeAll()
        gen2OtaRecovery.finish()
        // A suspended vendor OTA must not restore an explicitly removed binding.
        gen1OTAPeripheralID = nil
        cancelPairing()
        isPairingSessionActive = false
        isManualPairingScan = false
        systemTransportConnectedPeripheralIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: savedPeripheralIDKey)
        deviceName = nil
        deviceModel = nil
        deviceSN = nil
        resetBatteryDisplayForFreshRead()
        deviceIsCharging = false
        deviceStorage = nil
        deviceVersion2800 = nil
        deviceVersion6350 = nil
        cancelAboutDeviceInfoQuery()
        isQueryingAboutDeviceInfo = false
        cancelVersionsAndStorageQuery()
        pendingImportFileCount = 0
        pendingRecordingImportFileCount = 0
        isAIRecording = false
        isDeviceInfoReady = false
        identityPeripheralID = nil
        resetHomeMediaCaptureState()
        reconnectPeripheral = nil
        print("\(logTag) disconnectAndClearSession")
    }

    /// Selecting a bound card changes the exact target, never the account bindings.
    /// Repeated view refreshes keep the current target's three-attempt budget.
    @discardableResult
    func selectBoundHomeDevice(peripheralID: UUID, reason: String) -> Bool {
        guard !isPairingSessionActive, !isUserInitiatedPairingConnect else { return false }
        // A passive home refresh can select a card without activating Bluetooth.
        guard prepareCentralManager() else { return true }
        if savedPeripheralID() == peripheralID {
            homeSelectionTargetID = peripheralID
            ensureConnected(reason: reason)
            if !isReady, !isConnectionInProgress {
                _ = reconnectSavedPeripheralWithoutSystemConnection(source: reason)
            }
            return true
        }
        guard !isFirmwareUpgradeFlowBusy, gen1OTAPeripheralID == nil,
              !isAIVisionTransferBusy, !isVideoStarting, !isVideoRecording, !isVideoStopping,
              !isTakingPhoto, !isAIRecording,
              deviceRuntimeStatus == .standby || deviceRuntimeStatus == .unknown else { return false }
        if let oldID = savedPeripheralID() {
            guard !gen1HotspotCleanup.isPending(oldID) else { return false }
            homeSelectionRetryPolicies[oldID] = boundBLEReconnectPolicy
        }
        let retryPolicies = homeSelectionRetryPolicies
        disconnectAndClearSession()
        homeSelectionRetryPolicies = retryPolicies
        homeSelectionTargetID = peripheralID
        savePeripheralID(peripheralID)
        pendingBoundSerialNumbers = [peripheralID.uuidString]
        boundBLEReconnectPolicy = homeSelectionRetryPolicies[peripheralID] ?? BoundBLEReconnectPolicy()
        userInitiatedDisconnect = false
        autoReconnectEnabled = true
        standingConnectAllowed = true
        reconnectPeripheral = centralManager.state == .poweredOn
            ? centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first : nil
        connectLog("home card connection target selected", detail: "reason=\(reason) id=\(peripheralID.uuidString) failedAttempts=\(boundBLEReconnectPolicy.failedAttempts)")
        ensureConnected(reason: reason)
        if !isReady, !isConnectionInProgress {
            _ = reconnectSavedPeripheralWithoutSystemConnection(source: reason)
        }
        return true
    }

    /// Explicit retry reopens the budget; page appearances and polling never do.
    @discardableResult
    func retryBoundHomeDevice(
        peripheralID: UUID, reason: String, allowAuthorizationRequest: Bool = false
    ) -> Bool {
        guard !isPairingSessionActive, !isUserInitiatedPairingConnect,
              gen1OTAPeripheralID == nil, !isFirmwareUpgradeFlowBusy,
              !isManualHardReconnectCentralTransitionInProgress else { return false }
        guard prepareCentralManager(allowAuthorizationRequest: allowAuthorizationRequest) else { return false }
        if savedPeripheralID() != peripheralID {
            var retry = BoundBLEReconnectPolicy()
            retry.beginUserRetry()
            homeSelectionRetryPolicies[peripheralID] = retry
            return selectBoundHomeDevice(peripheralID: peripheralID, reason: reason)
        }
        guard !isReady, !isConnectionInProgress else { return true }
        guard boundReconnectScanTargetID != peripheralID, !isManualReconnectScan,
              !isManualHardReconnectAttemptInProgress else { return true }
        if case .failed = connectionState,
           manualHardReconnectPeripheralID == peripheralID,
           freshlyRetrievedSystemConnectedPeripheral(matching: peripheralID) != nil {
            return hardReconnectAfterUserTap(peripheralID: peripheralID)
        }
        boundBLEReconnectPolicy.beginUserRetry()
        boundBLEAttemptFailureCounted = false
        homeSelectionRetryPolicies[peripheralID] = boundBLEReconnectPolicy
        cancelManualHardReconnectState(reason: "explicit home retry")
        homeSelectionTargetID = peripheralID
        userInitiatedDisconnect = false
        autoReconnectEnabled = true
        standingConnectAllowed = true
        lastManualReconnectFailure = nil
        connectLog("explicit home BLE retry", detail: "source=\(reason) id=\(peripheralID.uuidString) resetAutomaticBudget=true retry=cached_UUID_connect fallback=exact_UUID_scan_if_cache_missing")
        ensureConnected(reason: reason)
        if !isReady { startSystemReconnectMonitor() }
        return true
    }

    /// 配对弹窗扫描阶段：后台连接探测协议服务（尚未由用户点「配对」）。
    var isPairingListProbeInProgress: Bool {
        guard isPairingSessionActive, isManualPairingScan else { return false }
        if isProbingService { return true }
        switch connectionState {
        case .connecting, .discoveringServices:
            return hasStartedConnect
        default:
            return false
        }
    }

    /// 设置单次录像最大时长（recordtime）。
    @discardableResult
    func setRecordTime(seconds: Int) -> Bool {
        guard ensureDeviceAvailable(for: "setRecordTime") else { return false }
        guard !isRecordDurationSettingPending else { return false }
        let sent = sendCommand(AstraA1BleProtocol.buildRecordTimeCommand(seconds: seconds))
        guard sent, deviceGeneration == .gen1G5K61 else { return sent }
        guard let token = gen1RecordDurationSetting.beginSet(seconds: seconds),
              let target = connectedPeripheral?.identifier else { return false }
        isRecordDurationSettingPending = true
        recordDurationSettingResult = nil
        DebugLogStore.logBLEEvent("Gen1 record duration set queued", detail: "target=\(target) requestedSeconds=\(seconds) token=\(token) queued_is_not_device_confirmation")
        // Do not repeat SET. Give firmware time to apply it, then query twice.
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.connectedPeripheral?.identifier == target,
                      self.isDeviceAvailable, self.deviceGeneration == .gen1G5K61,
                      self.gen1RecordDurationSetting.token == token,
                      self.gen1RecordDurationSetting.isPending,
                      self.isDeviceRuntimeIdle, !self.isVideoStarting,
                      !self.isVideoRecording, !self.isVideoStopping,
                      !self.isTakingPhoto, !self.isAIRecording,
                      !self.isAIVisionTransferBusy, !self.isFirmwareUpgradeFlowBusy else { return }
                if self.sendGen1Command(command: Gen1Commands.recordDurationQuery) {
                    _ = self.gen1RecordDurationSetting.beginVerificationQuery(token: token)
                    DebugLogStore.logBLEEvent("Gen1 record duration readback sent", detail: "target=\(target) requestedSeconds=\(seconds) token=\(token) delay=\(delay)")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.connectedPeripheral?.identifier == target,
                  self.gen1RecordDurationSetting.finish(token: token) else { return }
            self.publishRecordDurationSettingResult()
        }
        return true
    }

    private func publishRecordDurationSettingResult() {
        isRecordDurationSettingPending = gen1RecordDurationSetting.isPending
        recordDurationSettingResult = gen1RecordDurationSetting.result
        if let result = recordDurationSettingResult {
            DebugLogStore.logBLEEvent("Gen1 record duration verification finished", detail: "target=\(deviceBluetoothIdentifier ?? "none") token=\(result.token) outcome=\(result.outcome)")
        }
    }

    /// 设置/查询录像分辨率（setvidres0/getvidres0）。
    @discardableResult
    func setVideoResolution(profile: UInt8) -> Bool {
        guard deviceGeneration == .gen2 else { return false }
        guard ensureDeviceAvailable(for: "setVideoResolution") else { return false }
        return sendCommand(AstraA1BleProtocol.buildSetVideoResolutionCommand(profile: profile))
    }

    @discardableResult
    func queryVideoResolution() -> Bool {
        guard deviceGeneration == .gen2 else { return false }
        guard isReady else { return false }
        return sendCommand(AstraA1BleProtocol.buildGetVideoResolutionCommand())
    }

    /// 设置/查询摘下休眠（setweardet/getweardet）。
    @discardableResult
    func setWearDetection(enabled: Bool) -> Bool {
        guard ensureDeviceAvailable(for: "setWearDetection") else { return false }
        return sendCommand(AstraA1BleProtocol.buildSetWearDetectionCommand(enabled: enabled))
    }

    @discardableResult
    func queryWearDetection() -> Bool {
        guard isReady else { return false }
        return sendCommand(AstraA1BleProtocol.buildGetWearDetectionCommand())
    }

    /// 同步识图质量档位（imgrecset0）。
    @discardableResult
    func syncAIVisionLevel(_ level: UInt8) -> Bool {
        guard ensureDeviceAvailable(for: "syncAIVisionLevel") else { return false }
        return sendCommand(AstraA1BleProtocol.buildAIVisionSetLevelCommand(level: level))
    }

    // MARK: - Gen2 indicator brightness

    @discardableResult
    func queryIndicatorBrightness() -> Bool {
        startIndicatorBrightnessRequest(.query)
    }

    @discardableResult
    func setIndicatorBrightness(level: IndicatorBrightnessLevel) -> Bool {
        guard ensureDeviceAvailable(for: "setIndicatorBrightness") else { return false }
        return startIndicatorBrightnessRequest(.set(level))
    }

    private func startIndicatorBrightnessRequest(_ request: Gen2IndicatorBrightnessState.Request) -> Bool {
        guard deviceGeneration == .gen2, isReady, !isFirmwareUpgradeFlowBusy,
              !isInitialDeviceInfoQueryInProgress, !isAIVisionTransferBusy,
              let target = connectedPeripheral?.identifier,
              let id = indicatorBrightness.begin(request) else { return false }
        indicatorBrightnessTask?.cancel()
        indicatorBrightnessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...Gen2IndicatorBrightnessState.maximumWriteAttempts {
                guard !Task.isCancelled, self.indicatorBrightness.pending?.id == id else { return }
                guard self.isReady, self.deviceGeneration == .gen2,
                      self.connectedPeripheral?.identifier == target else {
                    self.resetIndicatorBrightness()
                    return
                }
                guard !self.isFirmwareUpgradeFlowBusy, !self.isAIVisionTransferBusy else {
                    self.indicatorBrightness.finish(id: id, failure: .sendFailed)
                    return
                }
                let sent = self.sendCommand(request.packet)
                self.indicatorBrightness.recordWrite(id: id, accepted: sent)
                DebugLogStore.logBLEEvent("indicator brightness write",
                    detail: "request=\(id) operation=\(request) attempt=\(attempt) queued=\(sent); queued_is_not_device_ack")
                if sent {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(Gen2IndicatorBrightnessState.responseTimeout * 1_000_000_000))
                    } catch { return }
                    guard !Task.isCancelled, self.connectedPeripheral?.identifier == target else { return }
                    if self.indicatorBrightness.finish(id: id, failure: .timeout) {
                        DebugLogStore.logBLEEvent("indicator brightness reply timed out",
                            detail: "request=\(id) operation=\(request) old_firmware_may_not_support_command=true")
                    }
                    return
                }
                if attempt < Gen2IndicatorBrightnessState.maximumWriteAttempts {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(Gen2IndicatorBrightnessState.retryInterval * 1_000_000_000))
                    } catch { return }
                }
            }
            self.indicatorBrightness.finish(id: id, failure: .sendFailed)
        }
        return true
    }

    /// Initial device-info commands have a paced queue; query after it settles.
    /// Also covers recovered connections that only refresh battery information.
    private func scheduleIndicatorBrightnessQuery() {
        indicatorBrightnessInitialQuery?.cancel()
        guard deviceGeneration == .gen2, let target = connectedPeripheral?.identifier else { return }
        indicatorBrightnessInitialQuery = Task { @MainActor [weak self] in
            // markReady schedules its initial info queue after 150 ms.
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            for _ in 0..<45 {
                guard !Task.isCancelled, let self, self.isReady,
                      self.deviceGeneration == .gen2, self.connectedPeripheral?.identifier == target else { return }
                if self.indicatorBrightness.isPending || self.indicatorBrightness.level != nil { return }
                if self.queryIndicatorBrightness() { return }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }

    private func resetIndicatorBrightness() {
        indicatorBrightnessInitialQuery?.cancel()
        indicatorBrightnessInitialQuery = nil
        indicatorBrightnessTask?.cancel()
        indicatorBrightnessTask = nil
        indicatorBrightness.reset()
    }

    /// 恢复出厂设置（factreset0）。
    @discardableResult
    func factoryResetDevice() -> Bool {
        guard unpairFactoryResetConfirmation == nil else { return false }
        guard ensureDeviceAvailable(for: "factoryResetDevice") else { return false }
        factoryResetResult = nil
        let sent = sendCommand(AstraA1BleProtocol.buildFactoryResetCommand())
        if sent, deviceGeneration == .gen1G5K61 {
            gen1FactoryResetGeneration += 1
            let generation = gen1FactoryResetGeneration
            for attempt in 1...2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt * 2)) { [weak self] in
                    guard let self, self.gen1FactoryResetGeneration == generation,
                          self.factoryResetResult == nil else { return }
                    _ = self.sendGen1Command(command: Gen1Commands.factoryReset)
                }
            }
        }
        return sent
    }

    /// Device success acknowledgement is required before removing the server binding.
    func resetDeviceBeforeUnpair() async throws {
        try Task.checkCancellation()
        guard unpairFactoryResetConfirmation == nil,
              deviceGeneration != .unknown, isDeviceAvailable,
              !isFirmwareUpgradeFlowBusy,
              let targetID = connectedPeripheral?.identifier else {
            throw ImportBLEError.failed(L10n.t("请连接当前眼镜后重试解绑", "Connect these glasses before unpairing"))
        }
        // Register the exact target before writing. Unpairing sends once and waits
        // for terminal success; a progress response must not trigger another reset.
        gen1FactoryResetGeneration += 1
        factoryResetResult = nil
        unpairFactoryResetConfirmation = FactoryResetConfirmation(
            targetID: targetID, deadline: ProcessInfo.processInfo.systemUptime + 30
        )
        defer { unpairFactoryResetConfirmation = nil }
        guard sendCommand(AstraA1BleProtocol.buildFactoryResetCommand()) else {
            throw ImportBLEError.sendFailed
        }
        connectLog("unbind: waiting for factory reset acknowledgement", detail: "target=\(targetID.uuidString) generation=\(deviceGeneration.rawValue) timeout=30s")
        while let confirmation = unpairFactoryResetConfirmation {
            try Task.checkCancellation()
            switch confirmation.outcome(now: ProcessInfo.processInfo.systemUptime) {
            case .succeeded:
                connectLog("unbind: factory reset confirmed", detail: "target=\(targetID.uuidString)")
                return
            case .failed:
                throw ImportBLEError.failed(L10n.t("眼镜恢复出厂设置失败，未解绑", "Factory reset failed. Glasses remain bound"))
            case .timedOut:
                throw ImportBLEError.failed(L10n.t("等待眼镜恢复出厂设置回复超时，未解绑，请重新连接后重试", "Factory reset confirmation timed out. Reconnect and retry unpairing"))
            case .waiting: break
            }
            guard connectedPeripheral?.identifier == targetID, isReady else {
                throw ImportBLEError.failed(L10n.t("尚未确认恢复出厂设置成功，眼镜已断开，未解绑", "Glasses disconnected before factory reset was confirmed. They remain bound"))
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ImportBLEError.failed(L10n.t("恢复出厂设置已取消，未解绑", "Factory reset cancelled. Glasses remain bound"))
    }

    /// 进入/退出新手引导模式（guidectrl0）。
    @discardableResult
    func setGuideModeEnabled(_ enabled: Bool) -> Bool {
        if enabled, !ensureDeviceAvailable(for: "setGuideModeEnabled") { return false }
        if deviceGeneration == .gen1G5K61 {
            let canResume = gen1GuidePeripheralID == connectedPeripheral?.identifier && gen1GuideStep > 0
            return setGuideStep(enabled ? (canResume ? gen1GuideStep : 1) : 0)
        }
        let sent = sendCommand(AstraA1BleProtocol.buildGuideModeCommand(enable: enabled))
        print("\(logTag) guidectrl0 enable=\(enabled) sent=\(sent)")
        return sent
    }

    /// Identity/status queries and cleanup need BLE ready; business commands also need a device card.
    @discardableResult
    func sendCommand(_ data: Data) -> Bool {
        guard let sharedCommand = DeviceCommandAvailabilityPolicy.sharedCommand(in: data) else { return false }
        let requiresAvailableDevice = DeviceCommandAvailabilityPolicy.requiresAvailableDevice(
            sharedCommand: sharedCommand.name,
            payload: sharedCommand.payload
        )
        if requiresAvailableDevice, !ensureDeviceAvailable(for: sharedCommand.name) { return false }
        if deviceGeneration == .gen1G5K61 {
            guard let command = Gen1CommandAdapter.translate(data) else {
                print("[Gen1] Unsupported shared command; no bytes sent")
                return false
            }
            return sendGen1Command(command: command.code, payload: command.payload)
        }
        guard deviceGeneration == .gen2 else { return false }
        return writeProtocolPacket(data, requiresAvailableDevice: requiresAvailableDevice)
    }

    private func writeProtocolPacket(_ data: Data, requiresAvailableDevice: Bool, redactPayload: Bool = false,
                                     gen1Command: UInt8? = nil) -> Bool {
        guard case .ready = connectionState,
              let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic else {
            print("\(logTag) sendCommand failed: not ready or missing write characteristic")
            return false
        }

        let preferWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)
        if redactPayload {
            let type: CBCharacteristicWriteType = preferWithoutResponse ? .withoutResponse : .withResponse
            let maximum = peripheral.maximumWriteValueLength(for: type)
            DebugLogStore.logBLEEvent("Gen1 Wi-Fi write plan", detail: "target=\(peripheral.identifier) characteristic=\(characteristic.uuid) notifying=\(notifyCharacteristic?.isNotifying ?? false) writeType=\(preferWithoutResponse ? "withoutResponse" : "withResponse") maximumWriteBytes=\(maximum) frameBytes=\(data.count) queuedFragmentsBefore=\(pendingBLEWrites.count); payload=<redacted> local_write_is_not_device_ack")
        }
        if preferWithoutResponse {
            let chunkSize = max(1, peripheral.maximumWriteValueLength(for: .withoutResponse))
            let chunks = stride(from: 0, to: data.count, by: chunkSize).map {
                data.subdata(in: $0..<min(data.count, $0 + chunkSize))
            }
            if pendingBLEWrites.count + chunks.count > maxPendingBLEWrites {
                if redactPayload {
                    DebugLogStore.logBLEEvent("Gen1 Wi-Fi write rejected", detail: "reason=queue_full queuedFragments=\(pendingBLEWrites.count) newFragments=\(chunks.count) limit=\(maxPendingBLEWrites); packet_not_queued=true")
                }
                print("\(logTag) sendCommand dropped: write queue full (\(maxPendingBLEWrites))")
                return false
            }
            let packetID = UUID()
            if redactPayload {
                DebugLogStore.logBLEEvent("Gen1 Wi-Fi packet queued", detail: "packetID=\(packetID) fragments=\(chunks.count) fragmentSizes=\(chunks.map { $0.count }) frameBytes=\(data.count) payload=<redacted>")
            }
            pendingBLEWrites.append(contentsOf: chunks.map {
                PendingBLEWrite(data: $0, packetID: packetID, requiresAvailableDevice: requiresAvailableDevice,
                                redactPayload: redactPayload, gen1Command: gen1Command)
            })
            flushPendingBLEWrites()
            return true
        }

        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        if let gen1Command { recordGen1CommandSubmission(gen1Command) }
        print("\(logTag) sendCommand \(data.count) bytes to \(characteristic.uuid) withResponse")
        if redactPayload {
            DebugLogStore.logBLEEvent("Gen1 Wi-Fi credentials sent", detail: "bytes=\(data.count) payload=<redacted>")
        } else {
            DebugLogStore.logBLESent(data)
        }
        return true
    }

    /// 冲刷 withoutResponse 写队列；缓冲满时等 `peripheralIsReady`。
    private func flushPendingBLEWrites() {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic else {
            pendingBLEWrites.removeAll()
            activeBLEWritePacketID = nil
            return
        }
        while !pendingBLEWrites.isEmpty {
            if !peripheral.canSendWriteWithoutResponse {
                if pendingBLEWrites.contains(where: { $0.redactPayload }) {
                    DebugLogStore.logBLEEvent("Gen1 Wi-Fi write waiting", detail: "queuedFragments=\(pendingBLEWrites.count) canSendWriteWithoutResponse=false; awaiting_peripheralIsReady")
                }
                print("\(logTag) write queue pause remaining=\(pendingBLEWrites.count)")
                return
            }
            let write = pendingBLEWrites[0]
            if activeBLEWritePacketID != write.packetID,
               let command = write.gen1Command,
               command == Gen1Commands.battery || command == Gen1Commands.fileList,
               !isFirmwareUpgradeFlowBusy, gen1FirmwareUpgradeIdentity == nil,
               shouldDeferGen1BackgroundQueries || (command == Gen1Commands.battery && isTakingPhoto) {
                pendingBLEWrites.removeAll { $0.packetID == write.packetID }
                if command == Gen1Commands.battery { deferredBatteryQuery = true }
                else { deferredPendingImportQuery = true }
                DebugLogStore.logBLEEvent("Gen1 queued query deferred", detail: "command=\(String(format: "0x%02X", command)) reason=device_busy")
                continue
            }
            if write.requiresAvailableDevice,
               activeBLEWritePacketID != write.packetID,
               !ensureDeviceAvailable(for: "queued-device-command") {
                pendingBLEWrites.removeAll { $0.packetID == write.packetID }
                continue
            }
            // Finish fragments of an already-started packet to preserve framing; do not
            // start another business packet after its corresponding card disappears.
            activeBLEWritePacketID = write.packetID
            pendingBLEWrites.removeFirst()
            peripheral.writeValue(write.data, for: characteristic, type: .withoutResponse)
            if let command = write.gen1Command { recordGen1CommandSubmission(command) }
            print("\(logTag) sendCommand \(write.data.count) bytes to \(characteristic.uuid)")
            if write.redactPayload {
                DebugLogStore.logBLEEvent("Gen1 Wi-Fi credential fragment sent", detail: "packetID=\(write.packetID) bytes=\(write.data.count) remainingPacketFragments=\(pendingBLEWrites.filter { $0.packetID == write.packetID }.count) payload=<redacted>; submitted_to_CoreBluetooth_not_device_ack")
            } else {
                DebugLogStore.logBLESent(write.data)
            }
        }
        activeBLEWritePacketID = nil
    }

    private func clearPendingBLEWrites(reason: String) {
        guard !pendingBLEWrites.isEmpty else { return }
        if pendingBLEWrites.contains(where: { $0.redactPayload }) {
            DebugLogStore.logBLEEvent("Gen1 Wi-Fi pending writes cleared", detail: "reason=\(reason) queuedFragments=\(pendingBLEWrites.count); device_may_have_partial_packet=true")
        }
        print("\(logTag) clear write queue count=\(pendingBLEWrites.count) reason=\(reason)")
        pendingBLEWrites.removeAll()
        activeBLEWritePacketID = nil
    }

    // MARK: - First-generation G5K61

    private func recordGen1CommandSubmission(_ command: UInt8) {
        lastGen1CommandSent = (command, ProcessInfo.processInfo.systemUptime)
    }

    /// Claim only the current account's Gen1 main-firmware flow. AP import and
    /// firmware provisioning must never compete for the glasses' network state.
    func beginGen1FirmwareUpgrade() throws -> Gen1FirmwareUpgradeIdentity {
        if let targetID = connectedPeripheral?.identifier {
            try requireGen1HotspotCleanupFinished(for: targetID)
        }
        guard deviceGeneration == .gen1G5K61, isDeviceAvailable,
              let targetID = connectedPeripheral?.identifier, savedPeripheralID() == targetID,
              gen1APImportIdentity == nil, gen1FirmwareUpgradeIdentity == nil,
              !isFirmwareUpgradeFlowBusy, !isAIRecording, !isTakingPhoto, !isVideoRecording,
              isDeviceRuntimeIdle || deviceRuntimeStatus == .networkOperating,
              let accountID = gen1ImportAccount(for: targetID), !accountID.isEmpty else {
            throw Gen1FirmwareUpdateSession.Failure.unavailable
        }
        let identity = Gen1FirmwareUpgradeIdentity(targetID: targetID, accountID: accountID,
            hardwareSN: deviceSN, authorizationID: gen1ImportAuthorizationID)
        gen1FirmwareUpgradeIdentity = identity
        beginFirmwareUpgradeFlow()
        return identity
    }

    func isGen1FirmwareUpgradeCurrent(_ identity: Gen1FirmwareUpgradeIdentity) -> Bool {
        gen1FirmwareUpgradeIdentity == identity
            && identity.authorizationID == gen1ImportAuthorizationID
            && savedPeripheralID() == identity.targetID
            && (connectedPeripheral == nil || connectedPeripheral?.identifier == identity.targetID)
            && (!isReady || deviceGeneration == .gen1G5K61)
            && gen1ImportAccountProvider?(identity.targetID, identity.hardwareSN) == identity.accountID
    }

    func endGen1FirmwareUpgrade(_ identity: Gen1FirmwareUpgradeIdentity) {
        guard gen1FirmwareUpgradeIdentity == identity else { return }
        let stillCurrent = isGen1FirmwareUpgradeCurrent(identity)
        gen1FirmwareUpgradeIdentity = nil
        endFirmwareUpgradeFlow(reason: "gen1-main-ota-finished", preserveRuntimeStatus: !stillCurrent)
    }

    func beginGen1MediaImport(targetID: UUID) throws -> Gen1APImportIdentity {
        try requireGen1HotspotCleanupFinished(for: targetID)
        guard deviceGeneration == .gen1G5K61, isDeviceAvailable,
              connectedPeripheral?.identifier == targetID, savedPeripheralID() == targetID,
              gen1APImportIdentity == nil, !isFirmwareUpgradeFlowBusy,
              !isAIRecording, !isTakingPhoto, !isVideoRecording,
              isDeviceRuntimeIdle || deviceRuntimeStatus == .networkOperating,
              let accountID = gen1ImportAccountProvider?(targetID, deviceSN), !accountID.isEmpty else { throw Gen1APImportError.unavailable }
        let identity = Gen1APImportIdentity(targetID: targetID, token: UUID(), accountID: accountID, hardwareSN: deviceSN)
        gen1APImportIdentity = identity
        return identity
    }

    func isGen1MediaImportCurrent(_ identity: Gen1APImportIdentity) -> Bool {
        (!isReady || deviceGeneration == .gen1G5K61) && gen1APImportIdentity == identity && identity.matchesAccount(gen1ImportAccountProvider?(identity.targetID, identity.hardwareSN)) && identity.matches(
            savedID: savedPeripheralID(), connectedID: connectedPeripheral?.identifier
        )
    }

    func invalidateGen1MediaImportForLogout() {
        gen1APImportIdentity = nil
        gen1ImportAuthorizationID = UUID()
    }

    func endGen1MediaImport(_ identity: Gen1APImportIdentity, remainingFileCount: Int?) {
        guard gen1APImportIdentity == identity else { return }
        if isGen1MediaImportCurrent(identity), let remainingFileCount {
            pendingImportFileCount = max(0, remainingFileCount)
        }
        gen1APImportIdentity = nil
        // Late start-code replies must not be interpreted as recording start/stop ACKs.
        gen1HotspotReplyQuarantineUntil = ProcessInfo.processInfo.systemUptime + 5
    }

    func requireGen1HotspotCleanupFinished(for targetID: UUID) throws {
        guard gen1HotspotCleanup.isPending(targetID) else { return }
        gen1HotspotCleanup.resume(targetID)
        DebugLogStore.logWiFi("上次热点尚未收尾，阻止新操作", detail: "target=\(targetID)")
        throw Gen1APImportError.hotspotCleanupPending
    }

    func prepareGen1TransferCompletion(_ identity: Gen1APImportIdentity) -> Bool {
        guard isGen1MediaImportCurrent(identity) else { return false }
        return gen1HotspotCleanup.prepareForTransferCompletion(identity)
    }

    func gen1TransferCompletionFailed(_ identity: Gen1APImportIdentity) {
        gen1HotspotCleanup.transferCompletionFailed(identity)
    }

    func waitForGen1TransferCompletion(_ identity: Gen1APImportIdentity) async -> Gen1HotspotCleanup.Outcome {
        await gen1HotspotCleanup.waitForTransferCompletion(identity)
    }

    func closeGen1Hotspot(_ identity: Gen1APImportIdentity) async -> Gen1HotspotCleanup.Outcome {
        await gen1HotspotCleanup.close(identity)
    }

    @discardableResult
    func sendGen1Command(command: UInt8, payload: Data = Data()) -> Bool {
        sendGen1Command(command: command, payload: payload, hotspotCleanup: false)
    }

    @discardableResult
    private func sendGen1Command(command: UInt8, payload: Data, hotspotCleanup: Bool) -> Bool {
        if command == Gen1Commands.fileList, deferGen1QueryIfNeeded(.fileList) { return false }
        // Explicit OTA battery reads require a new reply, even when a recent
        // background poll exists. Rate-limit only queryBatteryOnly(), not 0x05 itself.
        let cleanupPending = connectedPeripheral.map { gen1HotspotCleanup.isPending($0.identifier) } ?? false
        // Shared Gen2 cleanup paths must not enqueue an unowned/duplicate Gen1
        // shutdown after the user switches devices. Only the coordinator sends 0x38.
        if command == Gen1Commands.closeHotspot, !hotspotCleanup {
            DebugLogStore.logBLEEvent("Gen1 unowned hotspot close blocked", detail: "use_owned_AP_cleanup")
            return false
        }
        let isRecordingCommand = Gen1APImportProtocol.isRecordingRequest(command: command, payload: payload)
        if Gen1APImportProtocol.blocksRecording(command: command, payload: payload,
                                               apActive: gen1APImportIdentity != nil,
                                               quarantined: cleanupPending || ProcessInfo.processInfo.systemUptime < gen1HotspotReplyQuarantineUntil) {
            mediaActionAlertMessage = L10n.t("相册导入刚结束或仍在进行，请稍后开始录音", "Album import is active or just ended. Wait before starting a recording")
            return false
        }
        let requiresAvailableDevice = DeviceCommandAvailabilityPolicy.requiresAvailableDevice(
            gen1Command: command,
            payload: payload
        )
        if cleanupPending, requiresAvailableDevice {
            mediaActionAlertMessage = Gen1APImportError.hotspotCleanupPending.localizedDescription
            DebugLogStore.logBLEEvent("Gen1 command blocked during hotspot cleanup", detail: "command=\(String(format: "0x%02X", command))")
            return false
        }
        if command == Gen1Commands.openHotspot, payload.isEmpty,
           gen1APImportIdentity?.targetID != connectedPeripheral?.identifier || gen1APImportIdentity == nil {
            return false
        }
        if gen1FirmwareUpgradeIdentity != nil, requiresAvailableDevice,
           ![Gen1Commands.wifiProvision, Gen1Commands.firmwareOTA, Gen1Commands.restart].contains(command) {
            DebugLogStore.logBLEEvent("Gen1 command deferred during firmware upgrade", detail: "command=\(String(format: "0x%02X", command))")
            return false
        }
        if requiresAvailableDevice,
           !ensureDeviceAvailable(for: "gen1-\(String(format: "%02X", command))") { return false }
        guard deviceGeneration == .gen1G5K61, isReady,
              let packet = try? Gen1ControlCodec.buildCommand(command: command, payload: payload) else { return false }
        if let importIdentity = gen1APImportIdentity,
           importIdentity.targetID == connectedPeripheral?.identifier,
           requiresAvailableDevice,
           !(command == Gen1Commands.openHotspot && payload.isEmpty),
           command != Gen1Commands.deviceStatusQuery {
            DebugLogStore.logBLEEvent("Gen1 command deferred during AP import", detail: "command=\(String(format: "0x%02X", command))")
            return false
        }
        if command == Gen1Commands.openHotspot, payload.isEmpty {
            gen1HotspotReplyTarget = connectedPeripheral?.identifier
            gen1HotspotReplyQuarantineUntil = ProcessInfo.processInfo.systemUptime + 25
        } else if isRecordingCommand, payload.first == 1 {
            gen1HotspotReplyQuarantineUntil = 0
        }
        if command == Gen1Commands.fileList { gen1MediaListAccumulator.begin() }
        if command == Gen1Commands.translateRecord {
            if payload.first == 1 { gen1TranslationRouter.onStartRequested() }
            else { gen1TranslationRouter.onStopRequested() }
        }
        if isRecordingCommand, payload.first == 1 {
            gen1RecordingStopTimeout?.cancel()
            guard Gen1AiRecordingManager.shared.start() else {
                mediaActionAlertMessage = Gen1AiRecordingManager.shared.lastError
                return false
            }
        }
        let sent = writeProtocolPacket(packet, requiresAvailableDevice: requiresAvailableDevice,
                                       redactPayload: command == Gen1Commands.wifiProvision,
                                       gen1Command: command)
        if sent, command == Gen1Commands.battery || command == Gen1Commands.fileList {
            let query: Gen1BackgroundQueryGate.Query = command == Gen1Commands.battery ? .battery : .fileList
            gen1BackgroundQueryGate.sent(query, at: ProcessInfo.processInfo.systemUptime)
            if command == Gen1Commands.fileList {
                needsFreshGen1FileList = false
                deferredPendingImportQuery = false
            } else {
                deferredBatteryQuery = false
            }
        }
        if command == Gen1Commands.translateRecord, !sent { gen1TranslationRouter.onStartFailed() }
        if isRecordingCommand {
            if !sent { finishGen1Recording() }
            else if payload.first == 1 { isAIRecording = true }
            else {
                // Keep tail PCM until the device's stop ACK; bound a lost ACK.
                gen1RecordingStopTimeout?.cancel()
                let timeout = DispatchWorkItem { [weak self] in self?.finishGen1Recording() }
                gen1RecordingStopTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
            }
        }
        return sent
    }

    @discardableResult
    func queryRecordDuration() -> Bool {
        guard !isRecordDurationSettingPending else { return false }
        return sendGen1Command(command: Gen1Commands.recordDurationQuery)
    }

    @discardableResult
    func setGuideStep(_ step: Int) -> Bool {
        DebugLogStore.logBLEEvent("Gen1 guide step requested", detail: "session=\(gen1GuideEventSessionID?.uuidString ?? "nil") target=\(connectedPeripheral?.identifier.uuidString ?? "nil") requestedStep=\(step) previousStep=\(gen1GuideStep)")
        guard (0...9).contains(step) else {
            DebugLogStore.logBLEEvent("Gen1 guide step rejected", detail: "step=\(step) reason=out_of_range")
            return false
        }
        if let owner = gen1GuideEventTargetID, gen1GuideEventSessionID != nil,
           owner == savedPeripheralID(), owner == connectedPeripheral?.identifier {
            gen1GuideStep = step
            gen1GuidePeripheralID = owner
        }
        if step > 0, !ensureDeviceAvailable(for: "setGuideStep") {
            DebugLogStore.logBLEEvent("Gen1 guide step rejected", detail: "step=\(step) reason=device_unavailable")
            return false
        }
        let sent = sendGen1Command(command: Gen1Commands.tutorial, payload: Data([UInt8(step), 0]))
        if sent { gen1GuideStep = step; gen1GuidePeripheralID = connectedPeripheral?.identifier }
        DebugLogStore.logBLEEvent("Gen1 guide step send result", detail: "step=\(step) queued=\(sent) ready=\(isReady) available=\(isDeviceAvailable); queued_is_not_device_ack")
        return sent
    }

    func resetTranslateRecordingState() {
        gen1TranslationRouter.discardPendingStream()
    }

    /// Give the vendor RCSP client exclusive ownership without deleting binding identity.
    func suspendNormalConnectionForGen1OTA() {
        gen1OTAPeripheralID = connectedPeripheral?.identifier ?? savedPeripheralID()
        cancelPairing()
        stopSystemReconnectMonitor()
    }

    func resumeNormalConnectionAfterGen1OTA() {
        guard let id = gen1OTAPeripheralID else { return }
        gen1OTAPeripheralID = nil
        guard savedPeripheralID() == id else { return }
        gen1OTAVerificationPeripheralID = id
        userInitiatedDisconnect = false
        autoReconnectEnabled = true
        _ = reconnectBoundDevice(boundSerialNumbers: [id.uuidString], reason: "gen1-bluetooth-ota-completed")
    }

    private func finishGen1Recording() {
        gen1RecordingStopTimeout?.cancel()
        gen1RecordingStopTimeout = nil
        Gen1AiRecordingManager.shared.stop()
        isAIRecording = false
        if let error = Gen1AiRecordingManager.shared.lastError { mediaActionAlertMessage = error }
    }

    private func resetGen1Session() {
        gen1BackgroundQueryGate.reset()
        needsFreshGen1FileList = false
        lastGen1ControlReceivedAt = nil
        lastGen1CommandSent = nil
        gen1ControlDiagnosticBudget.reset()
        gen1HotspotCleanup.connectionInterrupted()
        gen1MediaListAccumulator.begin()
        gen1ControlDecoder.reset()
        gen1VoiceDecoder.reset()
        gen1SequenceTracker.reset()
        gen1VoiceDeliveryTiming = TranslationAudioTiming()
        gen1TranslationRouter.reset()
        gen1FactoryResetGeneration += 1
        gen1RecordDurationSetting.reset()
        isRecordDurationSettingPending = false
        recordDurationSettingResult = nil
        settingsRecordDurationSeconds = nil
        deviceSystemName = nil
        deviceHardwareAddress = nil
        settingsVideoResolutionProfile = nil
        settingsWearDetectionEnabled = nil
        aiVoiceListeningDurationResponse = nil
        voiceWakeupResponse = nil
        factoryResetResult = nil
        finishGen1Recording()
    }

    private func handleGen1ControlData(_ data: Data, capturedAt: Date, receivedUptime: TimeInterval) {
        lastGen1ControlReceivedAt = receivedUptime
        let decoded = gen1ControlDecoder.appendWithDiagnostics(data)
        if gen1ControlDiagnosticBudget.record() == .record {
            DebugLogStore.logBLEEvent("Gen1 control receive", detail: "target=\(connectedPeripheral?.identifier.uuidString ?? "nil") callbackDelaySeconds=\(ProcessInfo.processInfo.systemUptime - receivedUptime) \(decoded.diagnosticSummary); payload=omitted", capturedAt: capturedAt)
        }
        if gen1FirmwareUpgradeIdentity != nil {
            DebugLogStore.logBLEEvent("Gen1 firmware control decode", detail: "target=\(connectedPeripheral?.identifier.uuidString ?? "nil") \(decoded.diagnosticSummary); payload=<redacted>", capturedAt: capturedAt)
        }
        if gen1GuideEventSessionID != nil {
            DebugLogStore.logBLEEvent("Gen1 guide control decode", detail: "session=\(gen1GuideEventSessionID!.uuidString) target=\(connectedPeripheral?.identifier.uuidString ?? "nil") \(decoded.diagnosticSummary)", capturedAt: capturedAt)
        }
        if gen1APImportIdentity != nil {
            DebugLogStore.logBLEEvent("Gen1 AP control decode", detail: "target=\(connectedPeripheral?.identifier.uuidString ?? "nil") \(decoded.diagnosticSummary); credentialPayload=<redacted>", capturedAt: capturedAt)
        }
        for frame in decoded.frames {
            if frame.command == Gen1Commands.openHotspot || frame.command == Gen1Commands.closeHotspot {
                let header = frame.raw.prefix(6).map { String(format: "%02X", $0) }.joined(separator: " ")
                let checksum = frame.raw.suffix(2).map { String(format: "%02X", $0) }.joined(separator: " ")
                let payload = frame.payload.count == 1 ? frame.payload.map { String(format: "%02X", $0) }.joined() : "<credentials-redacted>"
                DebugLogStore.logBLEEvent("Gen1 hotspot raw frame received", detail: "target=\(connectedPeripheral?.identifier.uuidString ?? "nil") command=\(String(format: "0x%02X", frame.command)) sender=\(frame.sender) receiver=\(frame.receiver) routingAccepted=\(frame.sender == 3 && frame.receiver == 2) apActive=\(gen1APImportIdentity != nil) rawBytes=\(frame.raw.count) header=\(header) payloadBytes=\(frame.payload.count) payload=\(payload) checksum=\(checksum)", capturedAt: capturedAt)
            }
            if gen1FirmwareUpgradeIdentity != nil {
                DebugLogStore.logBLEEvent("Gen1 firmware control frame", detail: "command=\(String(format: "0x%02X", frame.command)) sender=\(frame.sender) receiver=\(frame.receiver) payloadBytes=\(frame.payload.count) routingAccepted=\(frame.sender == 3 && frame.receiver == 2); payload=<redacted>", capturedAt: capturedAt)
            }
            let guideRelated = frame.command == Gen1Commands.tutorial || Gen1GuideStepState.MediaAction(command: frame.command) != nil
            if gen1GuideEventSessionID != nil, !guideRelated {
                // Step 9 can produce wake/status events instead of a tutorial ACK.
                // Preserve every validated command number, including empty frames,
                // without exposing audio, identity or Wi-Fi credential payloads.
                let canLogPayload = frame.payload.isEmpty || (
                    [Gen1Commands.voiceWakeup, Gen1Commands.aiVoiceStatus,
                     Gen1Commands.deviceStatusQuery, Gen1Commands.deviceStatusChanged].contains(frame.command)
                    && frame.payload.count <= 2
                )
                let raw = canLogPayload
                    ? frame.raw.map { String(format: "%02X", $0) }.joined(separator: " ")
                    : "<payload-redacted>"
                DebugLogStore.logBLEEvent("Gen1 guide other control frame received", detail: "session=\(gen1GuideEventSessionID!.uuidString) target=\(connectedPeripheral?.identifier.uuidString ?? "nil") command=\(String(format: "0x%02X", frame.command)) sender=\(frame.sender) receiver=\(frame.receiver) payloadBytes=\(frame.payload.count) waitingStep=\(gen1GuideStep) routingAccepted=\(frame.sender == 3 && frame.receiver == 2) busy=\(frame.isBusy) aiHandlerPresent=\(aiVoiceNotifyHandler != nil); not_tutorial_completion\n\(raw)", capturedAt: capturedAt)
            }
            if guideRelated {
                let raw = frame.raw.prefix(96).map { String(format: "%02X", $0) }.joined(separator: " ")
                DebugLogStore.logBLEEvent("Gen1 guide control frame received", detail: "session=\(gen1GuideEventSessionID?.uuidString ?? "nil") target=\(connectedPeripheral?.identifier.uuidString ?? "nil") command=\(String(format: "0x%02X", frame.command)) sender=\(frame.sender) receiver=\(frame.receiver) payloadBytes=\(frame.payload.count) waitingStep=\(gen1GuideStep) guideHandler=\(gen1GuideEventHandler != nil) mediaHandler=\(gen1GuideMediaHandler != nil) rawTruncated=\(frame.raw.count > 96)\n\(raw)", capturedAt: capturedAt)
            }
            guard frame.sender == 3, frame.receiver == 2 else {
                if guideRelated { DebugLogStore.logBLEEvent("Gen1 guide frame ignored", detail: "reason=wrong_sender_or_receiver", capturedAt: capturedAt) }
                continue
            }
            let cleanupPending = connectedPeripheral.map { gen1HotspotCleanup.isPending($0.identifier) } ?? false
            if let targetID = connectedPeripheral?.identifier {
                gen1HotspotCleanup.receive(targetID: targetID, command: frame.command, payload: frame.payload)
            }
            gen1ControlSubject.send(frame)
            let payload = frame.payload
            // Only exact, bounded control frames are safe to dump. Hotspot,
            // Wi-Fi credentials, audio and image payloads are never included.
            if [Gen1Commands.takePhoto, Gen1Commands.startVideo, Gen1Commands.stopVideo,
                Gen1Commands.deviceStatusQuery, Gen1Commands.deviceStatusChanged,
                Gen1Commands.newFileCount, Gen1Commands.wearingState].contains(frame.command) {
                let hex = frame.raw.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
                DebugLogStore.logBLEEvent("Gen1 media control frame", detail: "command=\(String(format: "0x%02X", frame.command)) bytes=\(frame.raw.count) hex=\(hex) omittedBytes=\(max(0, frame.raw.count - 32))", capturedAt: capturedAt)
            }
            if frame.command == Gen1Commands.battery || frame.command == Gen1Commands.fileList {
                let query: Gen1BackgroundQueryGate.Query = frame.command == Gen1Commands.battery ? .battery : .fileList
                gen1BackgroundQueryGate.received(query, at: ProcessInfo.processInfo.systemUptime)
                if deferredBatteryQuery || deferredPendingImportQuery {
                    scheduleDeferredRoutineRetry(after: 0.6)
                }
            }
            if Gen1APImportProtocol.ownsReply(command: frame.command,
                                              sameTarget: cleanupPending || gen1HotspotReplyTarget == connectedPeripheral?.identifier,
                                              apActive: gen1APImportIdentity != nil,
                                              quarantined: cleanupPending || ProcessInfo.processInfo.systemUptime < gen1HotspotReplyQuarantineUntil) {
                let detail = payload.count == 1
                    ? "startCode=\(String(format: "0x%02X", payload.first!))"
                    : "credentialPayloadBytes=\(payload.count)"
                DebugLogStore.logBLEEvent("Gen1 AP reply routed separately from recording", detail: detail)
                continue
            }
            if frame.isBusy {
                if guideRelated { DebugLogStore.logBLEEvent("Gen1 guide frame ignored", detail: "reason=device_busy command=\(String(format: "0x%02X", frame.command))", capturedAt: capturedAt) }
                mediaActionToastMessage = L10n.t("眼镜正忙，请稍后重试", "Glasses are busy. Try again later.")
                if frame.command == Gen1Commands.aiImage {
                    aiVisionNotifyHandler?("gen1busy0", payload)
                }
                if frame.command == Gen1Commands.translateRecord {
                    routeGen1Voice(gen1TranslationRouter.onBusy())
                }
                if frame.command == Gen1Commands.aiRecord {
                    Gen1AiRecordingManager.shared.stop()
                    isAIRecording = false
                }
                if frame.command == Gen1Commands.startVideo || frame.command == Gen1Commands.stopVideo {
                    let action: UInt8 = frame.command == Gen1Commands.startVideo ? 2 : 3
                    emitGen1Canonical("actionrsp0", Data([action, 1, deviceRuntimeStatus.rawValue]))
                } else if frame.command == Gen1Commands.takePhoto {
                    resetHomeMediaCaptureState()
                }
                if frame.command == Gen1Commands.factoryReset {
                    gen1FactoryResetGeneration += 1
                    emitGen1Canonical("testresult", Data([0x13, 0]))
                }
                continue
            }
            switch frame.command {
            case Gen1Commands.battery, Gen1Commands.batteryChanged:
                guard let level = payload.first, level <= 100 else { continue }
                applyGen1DeviceInfo(key: "batt0", payload: Data("\(level)".utf8))
                scheduleNextBatteryPoll(after: batteryPollingInterval)
            case Gen1Commands.deviceName: applyGen1DeviceInfo(key: "name0", payload: payload)
            case Gen1Commands.deviceType: applyGen1DeviceInfo(key: "model", payload: payload)
            case Gen1Commands.snAuth: applyGen1DeviceInfo(key: "sn000", payload: payload)
            case Gen1Commands.systemName:
                deviceSystemName = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            case Gen1Commands.bleMac:
                deviceHardwareAddress = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            case Gen1Commands.bluetoothVersion: applyGen1DeviceInfo(key: "ver28", payload: payload, version: true)
            case Gen1Commands.firmwareVersion: applyGen1DeviceInfo(key: "ver63", payload: payload, version: true)
            case Gen1Commands.storage:
                if let value = Gen1StorageParser.parse(payload) {
                    applyGen1DeviceInfo(key: "stor0", payload: Data(value.utf8))
                }
            case Gen1Commands.newFileCount:
                needsFreshGen1FileList = true
                queryPendingImportFiles()
            case Gen1Commands.fileList:
                let count = gen1MediaListAccumulator.append(payload)
                emitGen1Canonical("hasnewfile", Data([count > 0 ? 1 : 0, UInt8(truncatingIfNeeded: count), UInt8(truncatingIfNeeded: count >> 8), 0]))
            case Gen1Commands.deviceStatusQuery, Gen1Commands.deviceStatusChanged:
                guard let raw = payload.first else { continue }
                let status = Gen1DeviceStatusMapper.toDomainStatus(raw).rawValue
                let statusName = AstraA1BleProtocol.DeviceRuntimeStatus(rawValue: status)?.name ?? "UNKNOWN"
                DebugLogStore.logBLEEvent(
                    "Gen1 runtime status mapping",
                    detail: "command=\(String(format: "0x%02X", frame.command)) rawStatus=\(raw) domainStatus=\(status) \(statusName)"
                )
                emitGen1Canonical("devstatus0", Data([status]))
            case Gen1Commands.takePhoto: emitGen1Canonical("actionrsp0", Data([1, 0, 1]))
            case Gen1Commands.startVideo: emitGen1Canonical("actionrsp0", Data([2, 0, 2]))
            case Gen1Commands.stopVideo:
                // Gen1 ACK has no current-status field. Do not invent STANDBY.
                logVideoCapture("stop-command-reply", detail: "payloadBytes=\(payload.count) completionConfirmed=false awaiting=device_standby")
                forceQueryDeviceStatus(reason: "gen1-video-stop-reply-awaiting-standby")
            case Gen1Commands.factoryReset:
                guard let state = payload.first else {
                    connectLog("Gen1 factory reset response ignored", detail: "reason=invalid_payload bytes=\(payload.count)")
                    continue
                }
                gen1FactoryResetGeneration += 1
                emitGen1Canonical("testresult", Data([0x13, state]))
            case Gen1Commands.eqSet, Gen1Commands.eqQuery:
                if let mode = payload.last, mode <= 2 { emitGen1Canonical("eqmodersp0", Data([0, mode])) }
            case Gen1Commands.wearingSet, Gen1Commands.wearingQuery:
                if let enabled = payload.last, enabled <= 1 { emitGen1Canonical("weardetrsp", Data([0, enabled])) }
            case Gen1Commands.recordDurationSet, Gen1Commands.recordDurationQuery:
                DebugLogStore.logBLEEvent("Gen1 record duration reply", detail: "command=\(String(format: "0x%02X", frame.command)) payloadBytes=\(payload.count) value=\(payload.first.map(Int.init) ?? -1) pending=\(isRecordDurationSettingPending) SET_ack_is_not_duration")
                if let seconds = gen1RecordDurationSetting.receive(command: frame.command, payload: payload) {
                    settingsRecordDurationSeconds = seconds
                    if isRecordDurationSettingPending, !gen1RecordDurationSetting.isPending {
                        publishRecordDurationSettingResult()
                    }
                }
            case Gen1Commands.tutorial:
                guard payload.count >= 2 else {
                    DebugLogStore.logBLEEvent("Gen1 guide acknowledgement ignored", detail: "reason=payload_too_short bytes=\(payload.count)", capturedAt: capturedAt)
                    continue
                }
                if let source = connectedPeripheral?.identifier, let handler = gen1GuideEventHandler {
                    handler(source, capturedAt, Int(payload[0]), Int(payload[1]))
                } else {
                    DebugLogStore.logBLEEvent("Gen1 guide acknowledgement ignored", detail: "reason=no_active_guide step=\(payload[0]) result=\(payload[1])", capturedAt: capturedAt)
                }
            case Gen1Commands.mediaPlay, Gen1Commands.mediaPause, Gen1Commands.mediaNext, Gen1Commands.mediaPrevious:
                if let source = connectedPeripheral?.identifier, let handler = gen1GuideMediaHandler {
                    handler(source, capturedAt, frame.command)
                } else {
                    DebugLogStore.logBLEEvent("Gen1 media event not consumed", detail: "command=\(String(format: "0x%02X", frame.command)) reason=no_active_guide; no_cross_app_forwarding", capturedAt: capturedAt)
                }
            case Gen1Commands.aiImage:
                aiVisionNotifyHandler?("gen1image0", payload)
            case Gen1Commands.aiVoiceStatus:
                if payload.first == 1, payload.count == 1 || payload[1] <= 1 {
                    gen1TranslationRouter.onAIWakeup()
                }
                aiVoiceNotifyHandler?("gen1voiceStatus", payload)
            case Gen1Commands.voiceWakeup:
                // Firmware reports utterance boundaries here when transport=BLE.
                if payload.count >= 2, payload[1] == 1 {
                    if payload.first == 1 { gen1TranslationRouter.onAIWakeup() }
                    aiVoiceNotifyHandler?("gen1voiceStatus", payload)
                }
            case Gen1Commands.translateRecord:
                DebugLogStore.logBLEEvent("Gen1 translation command reply", detail: "target=\(deviceBluetoothIdentifier ?? "nil") payloadBytes=\(payload.count) status=\(payload.count == 1 ? payload.first.map(Int.init) ?? -1 : -1); ACK_is_not_audio_END")
                if payload.count == 1, let status = payload.first {
                    routeGen1Voice(gen1TranslationRouter.onAck(status))
                }
            case Gen1Commands.aiRecord:
                guard let status = payload.first else { continue }
                if status == 1 { isAIRecording = Gen1AiRecordingManager.shared.start() }
                else if status == 0 || status == 2 { finishGen1Recording() }
            case Gen1Commands.pcmAudio:
                if !Gen1AiRecordingManager.shared.appendPCM(payload), isAIRecording {
                    isAIRecording = false
                    mediaActionAlertMessage = Gen1AiRecordingManager.shared.lastError
                    _ = sendGen1Command(command: Gen1Commands.aiRecord, payload: Data([0]))
                }
            case Gen1Commands.closeHotspot:
                emitGen1Canonical("closewifi", payload)
            default: break // All vendor-specific events also reach gen1ControlSubject.
            }
        }
    }

    private func emitGen1Canonical(_ command: String, _ payload: Data) {
        handleNotifyData(AstraA1BleProtocol.buildPacket(command: command, payload: payload))
    }

    private func applyGen1DeviceInfo(key: String, payload: Data, version: Bool = false) {
        var value = String(decoding: payload, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if version {
            guard let range = value.range(of: #"\d+(?:\.\d+){1,3}"#, options: .regularExpression) else { return }
            value = String(value[range])
        }
        guard !value.isEmpty else { return }
        let valueData = Data(value.utf8)
        guard valueData.count <= 65535 else { return }
        var body = Data(key.utf8)
        body.append(contentsOf: [UInt8(truncatingIfNeeded: valueData.count), UInt8(truncatingIfNeeded: valueData.count >> 8)])
        body.append(valueData)
        emitGen1Canonical("getdevinfo", body)
    }

    private var gen1VoiceDeliveryTiming = TranslationAudioTiming()

    private func handleGen1VoiceData(_ data: Data, receivedUptime: TimeInterval) {
        let handlerDelay = max(0, ProcessInfo.processInfo.systemUptime - receivedUptime)
        gen1VoiceDeliveryTiming.record(at: receivedUptime, delay: handlerDelay)
        for event in gen1VoiceDecoder.appendEvents(data) {
            switch event {
            case .frame(let frame, _):
                if frame.type == .start {
                    gen1VoiceDeliveryTiming = TranslationAudioTiming()
                    gen1VoiceDeliveryTiming.record(at: receivedUptime, delay: handlerDelay)
                }
                let sequence = gen1SequenceTracker.onFrame(frame)
                if case .duplicateOrLate = sequence { continue }
                if case .gap(let expected, let actual, let missing) = sequence {
                    DebugLogStore.logBLEEvent("Gen1 audio sequence gap", detail: "expected=\(expected) actual=\(actual) missing=\(missing)")
                }
                if frame.type != .data {
                    DebugLogStore.logBLEEvent("Gen1 audio stream boundary", detail: "type=\(frame.type) sequence=\(frame.sequence) flags=\(frame.flags) bytes=\(frame.payload.count) callbackToHandler={\(gen1VoiceDeliveryTiming.detail)}; excludes_delay_before_CoreBluetooth_callback")
                }
                routeGen1Voice(gen1TranslationRouter.onFrame(frame))
            case .dropped(let drop):
                DebugLogStore.logBLEEvent("Gen1 audio frame rejected", detail: "\(drop)")
            case .buffered: break
            }
        }
    }

    private func emitGen1TranslationStatus(_ status: UInt8) {
        DebugLogStore.logBLEEvent("Gen1 translation route status", detail: "status=\(status) handlerPresent=\(translationVoiceNotifyHandler != nil) frames=\(gen1TranslationFrameCount) opusBytes=\(gen1TranslationOpusBytes)")
        translationVoiceNotifyHandler?("trslatests", AstraA1BleProtocol.buildPacket(command: "trslatests", payload: Data([status])))
    }

    private var gen1TranslationFrameCount = 0
    private var gen1TranslationOpusBytes = 0

    private func routeGen1Voice(_ route: Gen1VoiceRoute) {
        switch route {
        case .ai(let frame):
            switch frame.type {
            case .start:
                DebugLogStore.logBLEEvent("Gen1 audio routed to AI", detail: "translationHandlerPresent=\(translationVoiceNotifyHandler != nil)")
                aiVoiceNotifyHandler?("gen1voiceStart", Data())
            case .data: aiVoiceNotifyHandler?("gen1opus00", frame.payload)
            case .end:
                if frame.flags == 0x80 { aiVoiceNotifyHandler?("gen1voiceEnd", Data()) }
            }
        case .translationStarted:
            gen1TranslationFrameCount = 0
            gen1TranslationOpusBytes = 0
            emitGen1TranslationStatus(1)
        case .translationData(let sequence, let opus):
            gen1TranslationFrameCount += 1
            gen1TranslationOpusBytes += opus.count
            if gen1TranslationFrameCount == 1 || gen1TranslationFrameCount.isMultiple(of: 100) {
                DebugLogStore.logBLEEvent("Gen1 translation DATA routed", detail: "sequence=\(sequence) frames=\(gen1TranslationFrameCount) opusBytes=\(gen1TranslationOpusBytes) handlerPresent=\(translationVoiceNotifyHandler != nil) callbackToHandler={\(gen1VoiceDeliveryTiming.detail)}")
            }
            translationVoiceNotifyHandler?("gen1trdat0", opus)
        case .translationStopAcknowledged:
            DebugLogStore.logBLEEvent("Gen1 translation STOP acknowledged", detail: "frames=\(gen1TranslationFrameCount) opusBytes=\(gen1TranslationOpusBytes); preserving DATA until END")
            translationVoiceNotifyHandler?("gen1trsak", Data([0]))
        case .translationStopRejected:
            DebugLogStore.logBLEEvent("Gen1 translation STOP busy", detail: "frames=\(gen1TranslationFrameCount); preserving tail and original END deadline")
            translationVoiceNotifyHandler?("gen1trsb0", Data([Gen1Commands.busy]))
        case .translationStopped: emitGen1TranslationStatus(0)
        case .translationStartFailed, .translationStreamError: emitGen1TranslationStatus(2)
        case .ignore: break
        }
    }

    // MARK: - Private

    private func beginScan() {
        guard let centralManager, centralManager.state == .poweredOn else { return }
        pendingStart = false
        stopScan()
        updateState(.scanning)

        if !isManualPairingScan {
            // 首页电量刷新等非配对场景：只接管已保存设备，禁止盲接其它同型号眼镜。
            if let savedID = savedPeripheralID() {
                let connected = centralManager.retrieveConnectedPeripherals(
                    withServices: Self.supportedServiceUUIDs
                )
                if let peripheral = connected.first(where: { $0.identifier == savedID }) {
                    print("\(logTag) found already-connected saved peripheral")
                    connect(to: peripheral, probing: false)
                    return
                }
                connectLog(
                    "saved peripheral not system-connected; skip automatic connect",
                    detail: "id=\(savedID.uuidString)"
                )
            }
        }

        if isManualPairingScan {
            print("\(logTag) beginScan pairing by device name containing model_name=\(pairingModelNameFilter ?? "nil")")
        } else {
            print("\(logTag) beginScan by protocol service UUID (name-independent)")
        }
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        if !isManualPairingScan {
            scheduleProbeStart()
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .scanning = self.connectionState {
                if self.isManualPairingScan {
                    print("\(self.logTag) pairing scan keep-alive")
                    if !self.centralManager.isScanning {
                        self.centralManager.scanForPeripherals(
                            withServices: nil,
                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                        )
                    }
                    self.schedulePairingScanTimeout()
                    return
                }
                self.stopScan()
                print("\(self.logTag) scan timeout, devices logged: \(self.loggedPeripheralIDs.count)")
                self.updateState(.failed(L10n.t("未找到设备，请确认眼镜已开机并进入配对状态", "Device not found. Make sure glasses are on and in pairing mode")))
            }
        }
        scanTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeoutSeconds, execute: workItem)
    }

    private func schedulePairingScanTimeout() {
        cancelScanTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .scanning = self.connectionState, self.isManualPairingScan {
                if !self.centralManager.isScanning {
                    self.centralManager.scanForPeripherals(
                        withServices: nil,
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                    )
                }
                self.schedulePairingScanTimeout()
            }
        }
        scanTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeoutSeconds, execute: workItem)
    }

    private func stopScan() {
        boundReconnectScanTimeoutWorkItem?.cancel()
        boundReconnectScanTimeoutWorkItem = nil
        boundReconnectScanTargetID = nil
        if let centralManager, centralManager.isScanning {
            centralManager.stopScan()
        }
    }

    private func cancelScanTimeout() {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
    }

    private func cancelProbeStart() {
        probeStartWorkItem?.cancel()
        probeStartWorkItem = nil
    }

    private func scheduleProbeStart() {
        cancelProbeStart()
        let workItem = DispatchWorkItem { [weak self] in
            self?.startProbingIfNeeded()
        }
        probeStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + probeStartDelaySeconds, execute: workItem)
    }

    private func resetConnectionHandles(preserveFailedRecoveryBudget: Bool = false) {
        resetIndicatorBrightness()
        pendingCharacteristicServices.removeAll()
        failedGATTContext = nil
        if !preserveFailedRecoveryBudget { failedGATTRetryGate.reset() }
        cancelConnectWatchdog()
        clearPendingBLEWrites(reason: "connection handles reset")
        resetGen1Session()
        deviceGeneration = .unknown
        gen1VoiceCharacteristic = nil
        connectedPeripheral = nil
        systemTransportGracePeripheralIDs.removeAll()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        batteryLevelCharacteristic = nil
        isServiceDiscovered = false
        isNotificationEnabled = false
        isProtocolNotificationEnabled = false
        resetDeviceStatusQueryGate(reason: "resetConnectionHandles")
        cancelInitialDeviceInfoQuery(reason: "resetConnectionHandles")
        routineRefreshWorkItem?.cancel()
        routineRefreshWorkItem = nil
        deferredRoutineRetryWorkItem?.cancel()
        deferredRoutineRetryWorkItem = nil
        deferredRoutineRetryAt = nil
        stopBatteryPolling()
        standingConnectPeripheralID = nil
        hasStartedConnect = false
        isProbingService = false
        pendingCharacteristicDiscoveries = 0
        gattDiscoveryAttempt = 0
        // 新链路要重新判定固件是否支持读通知特征。
        if !isRelinkingForLongPackets { hasRelinkedForLongPackets = false }
        notifyReadUnsupported = false
        notifyReadInFlight = false
        notifyReadWasIssued = false
        notifyReadRequestID = UUID()
        rawNotifyDiagnosticBudget.reset()
        notifyReadCommand = nil
        notifyReadAttempts = 0
        deviceVersionQueryGate.reset()
        cancelVersionsAndStorageQuery()
        cancelAboutDeviceInfoQuery()
        isQueryingAboutDeviceInfo = false
        deviceVersionQueryFailed = false
    }

    /// 断开或换外设时清掉 getdevinfo 缓存，避免首页仍显示上一副眼镜「已连接」。
    private func clearLiveDeviceIdentity(reason: String) {
        let hadIdentity = isDeviceInfoReady
            || deviceSN != nil
            || deviceName != nil
            || deviceModel != nil
            || identityPeripheralID != nil
        deviceName = nil
        deviceModel = nil
        deviceSN = nil
        isDeviceInfoReady = false
        identityPeripheralID = nil
        clearBatteryDisplay()
        deviceIsCharging = false
        if hadIdentity {
            print("\(logTag) cleared live device identity reason=\(reason)")
        }
    }

    private func savedPeripheralID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: savedPeripheralIDKey) else { return nil }
        return UUID(uuidString: raw)
    }

    /// 账号绑定设备的 `serial_number` 在 iOS 即外设 UUID。
    /// 换机 / 重装 / 重新登录后本地无 savedPeripheralID 时，用它认领系统已连接的眼镜，
    /// 否则首页会一直显示「未连接」（attach 因 no saved peripheral 被跳过）。
    func adoptBoundPeripheralIDs(_ serialNumbers: [String]) {
        guard savedPeripheralID() == nil else { return }
        guard prepareCentralManager() else {
            pendingBoundSerialNumbers = serialNumbers
            return
        }
        guard centralManager.state == .poweredOn else {
            pendingBoundSerialNumbers = serialNumbers
            connectLog("adopt deferred: bluetooth not powered on", detail: "candidates=\(serialNumbers.count)")
            return
        }
        pendingBoundSerialNumbers = []

        let candidates = serialNumbers.compactMap { value -> UUID? in
            UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !candidates.isEmpty else { return }

        let systemConnected = centralManager.retrieveConnectedPeripherals(
            withServices: Self.supportedServiceUUIDs
        )
        systemTransportConnectedPeripheralIDs.formUnion(systemConnected.map(\.identifier))
        if let peripheral = systemConnected.first(where: { candidates.contains($0.identifier) }) {
            connectLog("adopt bound peripheral from account", detail: "id=\(peripheral.identifier.uuidString)")
            savePeripheralID(peripheral.identifier)
            userInitiatedDisconnect = false
            autoReconnectEnabled = true
            standingConnectAllowed = true
            if peripheral.state == .connected {
                attachToConnectedPeripheral(peripheral)
            } else {
                armSystemAutoConnect(peripheral, force: true, systemTransportObserved: true)
            }
            return
        }

        let known = centralManager.retrievePeripherals(withIdentifiers: candidates)
        if let peripheral = known.first(where: { $0.state == .connected }) {
            connectLog("adopt bound peripheral already connected", detail: "id=\(peripheral.identifier.uuidString)")
            savePeripheralID(peripheral.identifier)
            userInitiatedDisconnect = false
            autoReconnectEnabled = true
            attachToConnectedPeripheral(peripheral)
            return
        }

        if let peripheral = known.first {
            connectLog("adopt bound peripheral, wait for system connection", detail: "id=\(peripheral.identifier.uuidString)")
            savePeripheralID(peripheral.identifier)
            userInitiatedDisconnect = false
            autoReconnectEnabled = true
            standingConnectAllowed = false
            reconnectPeripheral = peripheral
            updateState(.disconnected)
            startSystemReconnectMonitor()
            return
        }

        connectLog(
            "adopt bound peripheral: no match",
            detail: "candidates=\(candidates.count) systemConnected=\(systemConnected.count)"
        )
    }

    /// 配对流程结束（取消 / 设备已绑定）后恢复原有连接。
    /// `cancelPairing` 会置 `userInitiatedDisconnect` 并断开当前外设，
    /// 若不显式恢复，首页会一直显示「设备未连接」，直到切 Tab 触发 ensureConnected。
    func restoreBoundConnectionAfterPairing(boundSerialNumbers: [String]) {
        if case .ready = connectionState { return }
        guard !boundSerialNumbers.isEmpty || savedPeripheralID() != nil else { return }
        guard prepareCentralManager() else { return }

        userInitiatedDisconnect = false
        autoReconnectEnabled = true
        standingConnectAllowed = true
        isPairingSessionActive = false
        isManualPairingScan = false

        print("\(logTag) restore bound connection after pairing state=\(connectionState)")
        connectLog(
            "restore bound connection after pairing",
            detail: "state=\(connectStateDescription(connectionState)) boundCount=\(boundSerialNumbers.count)"
        )

        if savedPeripheralID() == nil {
            adoptBoundPeripheralIDs(boundSerialNumbers)
            return
        }

        if attachToAlreadyConnectedPeripheralIfPossible() { return }
        // GATT 刚被取消，系统侧可能还在收尾：交给监控轮询继续 attach（不发起常驻 connect）。
        startSystemReconnectMonitor()
    }

    /// 首页卡片点击重连：用户在系统蓝牙里断开眼镜后，手动把连接拉回来。
    /// 解绑/退登设置的 `userInitiatedDisconnect` 会挡住自动重连，这里显式解除。
    /// - Returns: `false` 表示本地与系统都查不到该外设，需要走重新配对流程。
    @discardableResult
    func reconnectBoundDevice(
        boundSerialNumbers: [String],
        expectedDeviceName: String? = nil,
        allowAnyProtocolDevice: Bool = false,
        reason: String
    ) -> Bool {
        guard prepareCentralManager() else { return false }
        print("\(logTag) reconnectBoundDevice reason=\(reason) state=\(connectionState)")
        connectLog(
            "reconnectBoundDevice",
            detail: "reason=\(reason) state=\(connectStateDescription(connectionState)) allowAny=\(allowAnyProtocolDevice)",
            direction: .sent
        )
        if case .ready = connectionState { return true }

        boundBLEReconnectPolicy.reset()
        clearManualHardReconnectRequirement(reason: "explicit bound device reconnect")

        userInitiatedDisconnect = false
        autoReconnectEnabled = true
        // 用户显式点卡片时也允许挂起目标连接。
        standingConnectAllowed = true

        if savedPeripheralID() == nil {
            adoptBoundPeripheralIDs(boundSerialNumbers)
        }

        guard centralManager.state == .poweredOn else {
            pendingBatteryRefresh = true
            print("\(logTag) reconnectBoundDevice deferred: bluetooth not powered on")
            return true
        }

        // 系统层已连接：直接接管 GATT，无需扫描。
        if attachToAlreadyConnectedPeripheralIfPossible() {
            return true
        }

        var candidates = Set(boundSerialNumbers.compactMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        if let saved = savedPeripheralID() {
            candidates.insert(saved)
        }
        guard !candidates.isEmpty else {
            print("\(logTag) reconnectBoundDevice: no candidate peripheral id, need re-pairing")
            return false
        }

        // 用户在系统蓝牙里「忽略此设备」后，retrievePeripherals 拿到的外设已失效，
        // 常驻 connect 永远等不到 didConnect，必须重新扫描发现。
        beginManualReconnectScan(
            candidates: candidates,
            expectedName: expectedDeviceName,
            allowAnyProtocolDevice: allowAnyProtocolDevice
        )
        return true
    }

    private func beginManualReconnectScan(
        candidates: Set<UUID>,
        expectedName: String?,
        allowAnyProtocolDevice: Bool
    ) {
        cancelAutomaticGATTRecovery(reason: "manual-reconnect-scan", resetAttempts: true)
        stopSystemReconnectMonitor()
        cancelScanTimeout()
        cancelProbeStart()
        cancelConnectWatchdog()
        stopScan()

        manualReconnectCandidateIDs = candidates
        manualReconnectExpectedName = expectedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        manualReconnectAllowAnyProtocolDevice = allowAnyProtocolDevice
        isManualReconnectScan = true
        isManualReconnectConnect = false
        lastManualReconnectFailure = nil
        isManualPairingScan = false
        isPairingSessionActive = false
        isBatteryRefreshMode = false
        isProbingService = false
        hasStartedConnect = false
        probeCandidates.removeAll()

        print("\(logTag) manual reconnect scan start candidates=\(candidates.count) name=\(manualReconnectExpectedName ?? "nil") allowAny=\(allowAnyProtocolDevice)")
        updateState(.scanning)
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        scheduleManualReconnectScanTimeout()
    }

    private func scheduleManualReconnectScanTimeout() {
        cancelManualReconnectScanTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isManualReconnectScan else { return }
            self.isManualReconnectScan = false
            self.stopScan()
            print("\(self.logTag) manual reconnect scan timeout: device not found")
            self.lastManualReconnectFailure = .notFound
            self.updateState(.failed(L10n.t("未找到设备", "Device not found")))
            // 用户已显式发起过重连：扫不到也保留常驻 connect，眼镜回到范围内自动连回。
            if let peripheral = self.reconnectPeripheral
                ?? self.savedPeripheralID().flatMap({
                    self.centralManager.retrievePeripherals(withIdentifiers: [$0]).first
                }) {
                self.armSystemAutoConnect(peripheral, force: true)
            }
        }
        manualReconnectScanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + manualReconnectScanTimeoutSeconds, execute: work)
    }

    private func cancelManualReconnectScanTimeout() {
        manualReconnectScanWorkItem?.cancel()
        manualReconnectScanWorkItem = nil
    }

    /// 优先按外设 UUID 认领；系统「忽略此设备」后 UUID 会变，再按协议服务 + 设备名兜底。
    private func manualReconnectMatches(
        _ peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> Bool {
        if manualReconnectCandidateIDs.contains(peripheral.identifier) { return true }
        guard advertisesProtocolService(advertisementData) else { return false }
        guard let expected = manualReconnectExpectedName, !expected.isEmpty else {
            return manualReconnectAllowAnyProtocolDevice
        }
        let name = resolvedName(for: peripheral, advertisementData: advertisementData)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return manualReconnectAllowAnyProtocolDevice }
        return name.localizedCaseInsensitiveContains(expected)
            || expected.localizedCaseInsensitiveContains(name)
    }

    private func savePeripheralID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: savedPeripheralIDKey)
        print("\(logTag) saved peripheral id \(id.uuidString)")
    }

    private func updateState(_ state: AstraA1ConnectionState) {
        let previous = connectionState
        if (state == .connecting && previous != .connecting)
            || (state == .discoveringServices && previous != .connecting
                && previous != .discoveringServices && previous != .enablingNotifications) {
            diagnosticConnectionGeneration &+= 1
        }
        if state == .ready, let id = connectedPeripheral?.identifier {
            diagnosticReadyObservation = (id, ProcessInfo.processInfo.systemUptime)
        }
        let becameReady: Bool = {
            if case .ready = state {
                if case .ready = previous { return false }
                return true
            }
            return false
        }()

        connectionState = state
        if previous == .ready, state != .ready {
            resetIndicatorBrightness()
        }
        switch state {
        case .idle:
            if boundReconnectScanTargetID != nil { stopScan() }
            cancelAutomaticGATTRecovery(reason: "state-idle", resetAttempts: true)
            stopSystemReconnectMonitor()
            stopBatteryPolling()
            statusMessage = pairingStatusMessage(for: .idle)
            markDeviceRuntimeStatusUnknown(reason: "idle")
        case .bluetoothUnavailable(let message):
            if boundReconnectScanTargetID != nil { stopScan() }
            cancelAutomaticGATTRecovery(reason: "bluetooth-unavailable", resetAttempts: true)
            stopSystemReconnectMonitor()
            stopBatteryPolling()
            statusMessage = message
            markDeviceRuntimeStatusUnknown(reason: "bluetoothUnavailable")
        case .scanning:
            statusMessage = pairingStatusMessage(for: .scanning)
        case .connecting:
            statusMessage = pairingStatusMessage(for: .connecting)
            markDeviceRuntimeStatusUnknown(reason: "connecting")
        case .discoveringServices:
            statusMessage = pairingStatusMessage(for: .discoveringServices)
        case .enablingNotifications:
            statusMessage = pairingStatusMessage(for: .enablingNotifications)
        case .ready:
            if boundReconnectScanTargetID != nil { stopScan() }
            boundBLEReconnectPolicy.reset()
            failedGATTContext = nil
            failedGATTRetryGate.reset()
            cancelAutomaticGATTRecovery(reason: "state-ready", resetAttempts: true)
            stopSystemReconnectMonitor()
            cancelManualReconnectScanTimeout()
            isManualReconnectScan = false
            isManualReconnectConnect = false
            lastManualReconnectFailure = nil
            cancelConnectWatchdog()
            cancelDiscoverServicesWorkItem()
            isBatteryRefreshMode = false
            isPairingSessionActive = false
            isManualPairingScan = false
            isUserInitiatedPairingConnect = false
            pairingModelNameFilter = nil
            statusMessage = L10n.t("连接成功", "Connected")
            startBatteryPolling()
            // 设备一进入就绪（刚连上/接管 GATT）就查询运行状态；等 notify 稳定后再发。
            if becameReady {
                scheduleIndicatorBrightnessQuery()
                if let peripheral = connectedPeripheral {
                    connectLog(
                        "BLE transport limits",
                        detail: "peripheral=\(peripheral.identifier) maxWriteWithoutResponse=\(peripheral.maximumWriteValueLength(for: .withoutResponse)) maxWriteWithResponse=\(peripheral.maximumWriteValueLength(for: .withResponse)) notifyProperties=\(notifyCharacteristic?.properties.rawValue ?? 0) rawDiagnosticLimit=256; write limits do not prove incoming notification size"
                    )
                }
                restoreCachedSoundEffectMode()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self else { return }
                    self.syncDeviceRuntimeStatusAfterConnected()
                    // 日常模式必须让固件直接发送 AVRCP/Absolute Volume 媒体键。
                    // App 异常退出或 BLE 重连后，防止 guidectrl0 遗留为开启状态，
                    // 导致双击、三击、滑动只上报 guideevt00 而不再控制系统媒体。
                    if self.deviceGeneration == .gen1G5K61 {
                        let resume = self.gen1GuideEventHandler != nil
                            && self.gen1GuideEventTargetID == self.connectedPeripheral?.identifier
                            && self.gen1GuidePeripheralID == self.connectedPeripheral?.identifier
                            && self.gen1GuideStep > 0
                        DebugLogStore.logBLEEvent("Gen1 guide reconnect decision", detail: "session=\(self.gen1GuideEventSessionID?.uuidString ?? "nil") ownerTarget=\(self.gen1GuideEventTargetID?.uuidString ?? "nil") connectedTarget=\(self.connectedPeripheral?.identifier.uuidString ?? "nil") resume=\(resume) step=\(self.gen1GuideStep)")
                        _ = self.setGuideModeEnabled(resume)
                    } else {
                        _ = self.setGuideModeEnabled(self.guideEventHandler != nil)
                    }
                }
            }
        case .failed(let message):
            cancelAutomaticGATTRecovery(
                reason: "state-failed",
                resetAttempts: manualHardReconnectPeripheralID == nil
            )
            stopSystemReconnectMonitor()
            stopBatteryPolling()
            cancelConnectWatchdog()
            cancelDiscoverServicesWorkItem()
            clearPendingBLEWrites(reason: "failed")
            statusMessage = message
            markDeviceRuntimeStatusUnknown(reason: "failed")
        case .disconnected:
            stopBatteryPolling()
            clearPendingBLEWrites(reason: "disconnected")
            statusMessage = L10n.t("设备已断开", "Disconnected")
            markDeviceRuntimeStatusUnknown(reason: "disconnected")
        }
        print("\(logTag) state -> \(state), message=\(statusMessage)")
        connectLog(
            "state -> \(connectStateDescription(state))",
            detail: "message=\(statusMessage) becameReady=\(becameReady)"
        )
    }

    private func markDeviceRuntimeStatusUnknown(reason: String) {
        homeVideoCapture.expireUnconfirmedStart()
        isVideoStarting = false
        cancelHomeVideoStartConfirmation()
        isTakingPhoto = false
        isVideoStopping = false
        applyDeviceRuntimeStatus(.unknown, source: reason)
    }

    private func pairingStatusMessage(for state: AstraA1ConnectionState) -> String {
        guard isPairingSessionActive else {
            switch state {
            case .idle, .scanning:
                return L10n.t("查找设备中...", "Looking for devices...")
            case .connecting:
                return L10n.t("正在连接设备...", "Connecting to device...")
            case .discoveringServices:
                return L10n.t("正在发现服务...", "Discovering services...")
            case .enablingNotifications:
                return L10n.t("正在配置通信...", "Configuring...")
            default:
                return statusMessage
            }
        }

        switch state {
        case .scanning:
            if let modelName = pairingModelNameFilter, !modelName.isEmpty {
                return L10n.t("正在搜索 \(modelName) 设备...", "Searching for \(modelName)...")
            }
            return L10n.t("正在搜索设备", "Searching for devices…")
        case .connecting, .discoveringServices, .enablingNotifications:
            return L10n.t("正在配对", "Pairing")
        default:
            return statusMessage
        }
    }

    private func addVerifiedPairingDevice(
        _ peripheral: CBPeripheral,
        displayName: String,
        rssi: Int
    ) {
        discoveredPeripherals[peripheral.identifier] = peripheral

        if let index = discoveredPairingDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            let existing = discoveredPairingDevices[index]
            if rssi > existing.rssi {
                discoveredPairingDevices[index] = DiscoveredBLEDevice(
                    id: peripheral.identifier,
                    displayName: displayName,
                    rssi: rssi
                )
            }
        } else {
            discoveredPairingDevices.append(
                DiscoveredBLEDevice(
                    id: peripheral.identifier,
                    displayName: displayName,
                    rssi: rssi
                )
            )
            print("\(logTag) pairing list + \(displayName) [\(peripheral.identifier.uuidString)]")
        }

        discoveredPairingDevices.sort { $0.rssi > $1.rssi }
    }

    private func finishPairingListProbe(for peripheral: CBPeripheral) {
        cancelConnectWatchdog()
        isProbingService = false
        hasStartedConnect = false
        activeProbeRSSI = nil
        centralManager.cancelPeripheralConnection(peripheral)
        resetConnectionHandles()
        updateState(.scanning)
        if !centralManager.isScanning {
            centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        schedulePairingScanTimeout()
        guard !shouldPauseBackgroundProbe() else {
            print("\(logTag) pairing list has devices, pause background probe")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.probeNextCandidate()
        }
    }

    private func resumePairingScanAfterFailure() {
        guard isPairingSessionActive else { return }
        isUserInitiatedPairingConnect = false
        hasStartedConnect = false
        resetConnectionHandles()
        isManualPairingScan = true
        updateState(.scanning)
        if !centralManager.isScanning {
            centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        schedulePairingScanTimeout()
    }

    /// 广播包里是否包含协议服务 UUID（不看名字）。
    private func advertisesProtocolService(_ advertisementData: [String: Any]) -> Bool {
        let lists = [
            advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
            advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]
        ]
        return lists.compactMap { $0 }.contains { !Set($0).isDisjoint(with: Self.supportedServiceUUIDs) }
    }

    private func connect(to peripheral: CBPeripheral, probing: Bool) {
        // 系统层已连接时不要再 connect，否则可能永远等不到 didConnect
        if peripheral.state == .connected {
            isProbingService = probing
            if probing && isPairingSessionActive {
                connectedPeripheral = peripheral
                peripheral.delegate = self
                beginDiscoverServices(on: peripheral, reason: "probe-already-connected")
                startConnectWatchdog(for: peripheral)
                return
            }
            attachToConnectedPeripheral(peripheral)
            return
        }

        guard !hasStartedConnect else { return }
        hasStartedConnect = true
        isProbingService = probing
        cancelScanTimeout()
        cancelProbeStart()
        stopScan()

        connectedPeripheral = peripheral
        reconnectPeripheral = peripheral
        peripheral.delegate = self
        updateState(.connecting)
        print("\(logTag) connecting \(peripheral.identifier.uuidString), probing=\(probing), state=\(peripheral.state.rawValue)")
        centralManager.connect(peripheral, options: nil)
        startConnectWatchdog(for: peripheral)
    }

    private func cancelConnectWatchdog() {
        gattWatchdogPolicy.cancel()
        connectWatchdogWorkItem?.cancel()
        connectWatchdogWorkItem = nil
    }

    private var canAutomaticallyRecoverGATT: Bool {
        guard !boundBLEReconnectPolicy.isExhausted else { return false }
        guard let centralManager else { return false }
        let targetID = connectedPeripheral?.identifier
            ?? reconnectPeripheral?.identifier
            ?? savedPeripheralID()
        let systemConnected = targetID.flatMap { systemConnectedPeripheral(matching: $0) } != nil
        return centralManager.state == .poweredOn
            && autoReconnectEnabled
            && !userInitiatedDisconnect
            && !isPairingSessionActive
            && !isManualReconnectConnect
            && manualHardReconnectPeripheralID == nil
            && systemConnected
    }

    private func cancelAutomaticGATTRecovery(reason: String, resetAttempts: Bool) {
        let hadRecovery = isAutomaticGATTRecoveryInProgress
            || automaticGATTRecoveryWorkItem != nil
            || automaticGATTRecoveryCancellationPeripheralID != nil
        automaticGATTRecoveryWorkItem?.cancel()
        automaticGATTRecoveryWorkItem = nil
        automaticGATTRecoveryGeneration += 1
        automaticGATTRecoveryCancellationPeripheralID = nil
        isAutomaticGATTRecoveryInProgress = false
        if resetAttempts {
            standingConnectRecoveryCount = 0
        }
        if hadRecovery {
            connectLog(
                "automatic GATT recovery cancelled",
                detail: "reason=\(reason) resetAttempts=\(resetAttempts)"
            )
        }
    }

    private func requireManualHardReconnect(for peripheral: CBPeripheral, reason: String) {
        guard freshlyRetrievedSystemConnectedPeripheral(matching: peripheral.identifier) != nil else {
            cancelAutomaticGATTRecovery(reason: "manual retry blocked: system disconnected", resetAttempts: true)
            manualHardReconnectPeripheralID = nil
            standingConnectAllowed = false
            standingConnectPeripheralID = nil
            resetConnectionHandles()
            updateState(.disconnected)
            startSystemReconnectMonitor()
            return
        }

        cancelAutomaticGATTRecovery(reason: "soft recovery exhausted", resetAttempts: false)
        stopSystemReconnectMonitor()
        cancelConnectWatchdog()
        cancelDiscoverServicesWorkItem()
        standingConnectAllowed = false
        standingConnectPeripheralID = nil
        hasStartedConnect = false
        isBatteryRefreshMode = false
        manualHardReconnectPeripheralID = peripheral.identifier
        reconnectPeripheral = peripheral
        let context = FailedGATTContext(
            central: centralManager, peripheral: peripheral, generation: deviceGeneration,
            write: writeCharacteristic, notify: notifyCharacteristic, voice: gen1VoiceCharacteristic
        )
        resetConnectionHandles(preserveFailedRecoveryBudget: true)
        failedGATTContext = context
        failedGATTRetryGate.noteFailure(now: ProcessInfo.processInfo.systemUptime)
        // Keep the link available for a late subscription result or manual hard retry.
        updateState(.failed(L10n.t("连接失败，请点击重试", "Connection failed. Tap to retry.")))
        connectLog(
            "manual hard reconnect required",
            detail: "reason=\(reason) attempts=\(standingConnectRecoveryCount) id=\(peripheral.identifier.uuidString)"
        )
        startSystemReconnectMonitor()
    }

    @discardableResult
    private func failManualHardReconnectIfNeeded(
        for peripheral: CBPeripheral,
        reason: String
    ) -> Bool {
        guard isManualHardReconnectAttemptInProgress else { return false }
        isManualHardReconnectAttemptInProgress = false
        pendingManualHardReconnectPeripheralID = nil
        manualHardReconnectLookupWorkItem?.cancel()
        manualHardReconnectLookupWorkItem = nil
        requireManualHardReconnect(for: peripheral, reason: "hard reconnect failed: \(reason)")
        return true
    }

    private func failOrRecoverConnectionPipeline(
        _ peripheral: CBPeripheral,
        reason: String,
        message: String
    ) {
        if failManualHardReconnectIfNeeded(for: peripheral, reason: reason) {
            return
        }
        if canAutomaticallyRecoverGATT {
            beginAutomaticGATTRecovery(for: peripheral, reason: reason)
            return
        }

        if !isPairingSessionActive, autoReconnectEnabled, !userInitiatedDisconnect,
           savedPeripheralID() == peripheral.identifier {
            recordBoundBLEAttemptFailure()
            if stopBoundReconnectIfExhausted() { return }
            centralManager.cancelPeripheralConnection(peripheral)
            startSystemReconnectMonitor()
        }

        hasStartedConnect = false
        isBatteryRefreshMode = false
        isManualReconnectConnect = false
        updateState(.failed(message))
    }

    /// 对齐 Android disconnect/close 后再 connectGatt：旧 GATT 未确认断开前，绝不发新 connect。
    private func beginAutomaticGATTRecovery(for peripheral: CBPeripheral, reason: String) {
        guard canAutomaticallyRecoverGATT else { return }
        guard !isAutomaticGATTRecoveryInProgress else {
            connectLog(
                "automatic GATT recovery already in progress",
                detail: "reason=\(reason) id=\(peripheral.identifier.uuidString)"
            )
            return
        }

        if reason != "unexpected-disconnect" {
            recordBoundBLEAttemptFailure()
            if stopBoundReconnectIfExhausted() { return }
        }

        automaticGATTRecoveryWorkItem?.cancel()
        automaticGATTRecoveryWorkItem = nil
        automaticGATTRecoveryGeneration += 1
        let generation = automaticGATTRecoveryGeneration
        isAutomaticGATTRecoveryInProgress = true
        stopSystemReconnectMonitor()
        cancelConnectWatchdog()
        cancelDiscoverServicesWorkItem()
        standingConnectPeripheralID = nil
        reconnectPeripheral = peripheral
        standingConnectAllowed = true
        hasStartedConnect = false
        isBatteryRefreshMode = false

        guard standingConnectRecoveryCount < maxStandingConnectRecoveryAttempts else {
            requireManualHardReconnect(for: peripheral, reason: reason)
            return
        }

        standingConnectRecoveryCount += 1
        automaticGATTRecoveryCancellationPeripheralID = peripheral.identifier
        resetConnectionHandles()
        updateState(.connecting)
        connectLog(
            "automatic GATT recovery: cancel old link",
            detail: "reason=\(reason) attempt=\(standingConnectRecoveryCount)/\(maxStandingConnectRecoveryAttempts) id=\(peripheral.identifier.uuidString) peripheralState=\(peripheralStateDescription(peripheral.state))",
            direction: .sent
        )

        if peripheral.state == .disconnected {
            completeAutomaticGATTRecoveryCancellation(
                for: peripheral,
                generation: generation,
                source: "already-disconnected"
            )
        } else {
            centralManager.cancelPeripheralConnection(peripheral)
            waitForAutomaticGATTRecoveryCancellation(
                of: peripheral,
                generation: generation,
                pollCount: 0
            )
        }
    }

    private func waitForAutomaticGATTRecoveryCancellation(
        of peripheral: CBPeripheral,
        generation: Int,
        pollCount: Int
    ) {
        automaticGATTRecoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            self.automaticGATTRecoveryWorkItem = nil
            guard self.automaticGATTRecoveryGeneration == generation,
                  self.isAutomaticGATTRecoveryInProgress,
                  self.automaticGATTRecoveryCancellationPeripheralID == peripheral.identifier else { return }

            if peripheral.state == .disconnected {
                self.completeAutomaticGATTRecoveryCancellation(
                    for: peripheral,
                    generation: generation,
                    source: "state-poll"
                )
                return
            }

            let nextPollCount = pollCount + 1
            if nextPollCount.isMultiple(of: 4) {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
            if nextPollCount.isMultiple(of: 20) {
                self.connectLog(
                    "automatic GATT recovery: waiting for disconnect",
                    detail: "id=\(peripheral.identifier.uuidString) seconds=\(Double(nextPollCount) * self.automaticGATTRecoveryPollSeconds) peripheralState=\(self.peripheralStateDescription(peripheral.state))"
                )
            }
            self.waitForAutomaticGATTRecoveryCancellation(
                of: peripheral,
                generation: generation,
                pollCount: nextPollCount
            )
        }
        automaticGATTRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + automaticGATTRecoveryPollSeconds,
            execute: work
        )
    }

    @discardableResult
    private func consumeAutomaticGATTRecoveryCancellation(
        for peripheral: CBPeripheral,
        source: String
    ) -> Bool {
        guard isAutomaticGATTRecoveryInProgress,
              automaticGATTRecoveryCancellationPeripheralID == peripheral.identifier else {
            return false
        }
        completeAutomaticGATTRecoveryCancellation(
            for: peripheral,
            generation: automaticGATTRecoveryGeneration,
            source: source
        )
        return true
    }

    private func completeAutomaticGATTRecoveryCancellation(
        for peripheral: CBPeripheral,
        generation: Int,
        source: String
    ) {
        guard automaticGATTRecoveryGeneration == generation,
              isAutomaticGATTRecoveryInProgress,
              automaticGATTRecoveryCancellationPeripheralID == peripheral.identifier else { return }

        automaticGATTRecoveryWorkItem?.cancel()
        automaticGATTRecoveryWorkItem = nil
        automaticGATTRecoveryCancellationPeripheralID = nil
        reconnectPeripheral = peripheral
        resetConnectionHandles()
        updateState(.connecting)
        connectLog(
            "automatic GATT recovery: old link closed",
            detail: "source=\(source) id=\(peripheral.identifier.uuidString) peripheralState=\(peripheralStateDescription(peripheral.state))",
            direction: .received
        )

        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            self.automaticGATTRecoveryWorkItem = nil
            guard self.automaticGATTRecoveryGeneration == generation,
                  self.isAutomaticGATTRecoveryInProgress else { return }
            guard self.canAutomaticallyRecoverGATT, !self.isReady else {
                self.cancelAutomaticGATTRecovery(reason: "reconnect no longer needed", resetAttempts: false)
                return
            }

            self.isAutomaticGATTRecoveryInProgress = false
            self.connectLog(
                "automatic GATT recovery: reconnect",
                detail: "id=\(peripheral.identifier.uuidString) peripheralState=\(self.peripheralStateDescription(peripheral.state))",
                direction: .sent
            )
            if peripheral.state == .connected {
                self.attachToConnectedPeripheral(peripheral)
            } else {
                self.armSystemAutoConnect(peripheral, force: true)
            }
        }
        automaticGATTRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + automaticGATTRecoveryResumeDelaySeconds,
            execute: work
        )
    }

    private func shouldIgnoreGATTCallback(from peripheral: CBPeripheral, event: String) -> Bool {
        if automaticGATTRecoveryCancellationPeripheralID == peripheral.identifier {
            connectLog(
                "GATT callback ignored during recovery cancellation",
                detail: "event=\(event) id=\(peripheral.identifier.uuidString)"
            )
            return true
        }
        guard connectedPeripheral === peripheral else {
            connectLog(
                "stale GATT callback ignored",
                detail: "event=\(event) id=\(peripheral.identifier.uuidString)"
            )
            return true
        }
        return false
    }

    private var gattRecoveryPhase: GATTRecoveryPhase? {
        switch connectionState {
        case .connecting: return .connecting
        case .discoveringServices: return .discoveringServices
        case .enablingNotifications: return .enablingNotifications
        default: return nil
        }
    }

    /// GATT 流水线看门狗；已绑定设备尚不可达时保留原生请求，不用 20 秒取消它。
    private func startConnectWatchdog(
        for peripheral: CBPeripheral,
        timeoutOverride: TimeInterval? = nil
    ) {
        cancelConnectWatchdog()
        guard let phase = gattRecoveryPhase else { return }
        let isStandingAttempt = standingConnectPeripheralID == peripheral.identifier
        let standingTimeout = standingConnectRecoveryCount == 0
            ? systemTransportConnectGraceSeconds
            : standingConnectRetryIntervalSeconds
        let timeout = timeoutOverride
            ?? (isStandingAttempt ? standingTimeout : connectWatchdogSeconds)
        let token: GATTWatchdogToken
        if isStandingAttempt {
            // A2DP audio, cached identity and connection-event registration are
            // insufficient. Only a real BLE event/query or connected state counts.
            let hasTransportEvidence = phase != .connecting
                || peripheral.state == .connected
                || systemTransportGracePeripheralIDs.contains(peripheral.identifier)
                || freshlyRetrievedSystemConnectedPeripheral(matching: peripheral.identifier) != nil
            guard let armed = gattWatchdogPolicy.armBoundReconnect(
                peripheralID: peripheral.identifier, phase: phase,
                hasTransportEvidence: hasTransportEvidence,
                now: ProcessInfo.processInfo.systemUptime, timeout: timeout
            ) else {
                connectLog("bound BLE waiting for reachability", detail: "id=\(peripheral.identifier.uuidString) nativeConnectRetained=true failureBudgetUnchanged=true peripheralState=\(peripheralStateDescription(peripheral.state))")
                return
            }
            token = armed
        } else {
            token = gattWatchdogPolicy.arm(
                peripheralID: peripheral.identifier, phase: phase,
                now: ProcessInfo.processInfo.systemUptime, timeout: timeout
            )
        }
        connectLog("GATT phase watchdog armed", detail: "phase=\(phase) seconds=\(timeout) generation=\(token.generation) id=\(peripheral.identifier.uuidString)")
        if isStandingAttempt {
            connectLog(
                "standing connect watchdog armed",
                detail: "id=\(peripheral.identifier.uuidString) seconds=\(timeout) recoveryAttempt=\(standingConnectRecoveryCount) peripheralState=\(peripheralStateDescription(peripheral.state))"
            )
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connectedPeripheral === peripheral,
                  let phase = self.gattRecoveryPhase,
                  self.gattWatchdogPolicy.accepts(
                    token, peripheralID: peripheral.identifier, phase: phase,
                    now: ProcessInfo.processInfo.systemUptime
                  ) else { return }
            self.gattWatchdogPolicy.cancel()
            self.connectWatchdogWorkItem = nil
            if case .ready = self.connectionState { return }
            let isStandingConnect = self.standingConnectPeripheralID == peripheral.identifier
            switch self.connectionState {
            case .connecting, .discoveringServices, .enablingNotifications:
                break
            default:
                // 常驻连接不改变首页状态；仅处理 CoreBluetooth 永久卡在 connecting 的情况。
                guard isStandingConnect, peripheral.state == .connecting else { return }
            }

            if peripheral.state == .connected {
                // 连接对象仍保留上一轮完整服务/通知句柄时，说明状态被重复回调误改。
                // 直接恢复 ready，禁止 watchdog 反复 discoverServices 且计数不增长。
                if self.isServiceDiscovered,
                   self.isProtocolNotificationEnabled,
                   self.writeCharacteristic != nil {
                    self.connectLog(
                        "connect watchdog: restore ready from valid GATT handles",
                        detail: "id=\(peripheral.identifier.uuidString)"
                    )
                    self.markReadyIfNeeded()
                    return
                }
                if self.isProbingService && self.isPairingSessionActive {
                    self.handleProbeFailed(reason: "probe watchdog timeout")
                    return
                }
                if case .enablingNotifications = self.connectionState {
                    self.connectLog(
                        "connect watchdog: notification setup timed out",
                        detail: "id=\(peripheral.identifier.uuidString)"
                    )
                    if self.isUserInitiatedPairingConnect && self.isPairingSessionActive {
                        self.retryUserPairingConnect(reason: "notification setup timeout")
                    } else {
                        self.failOrRecoverConnectionPipeline(
                            peripheral,
                            reason: "notification-setup-timeout",
                            message: L10n.t("通信配置超时，请点击重试", "Communication setup timed out. Tap to retry")
                        )
                    }
                    return
                }
                if self.isUserInitiatedPairingConnect && self.isPairingSessionActive {
                    if self.gattDiscoveryAttempt >= self.maxGATTDiscoveryAttempts {
                        self.isUserInitiatedPairingConnect = false
                        self.hasStartedConnect = false
                        self.updateState(.failed(L10n.t("连接超时，请重试", "Connection timed out. Try again.")))
                        return
                    }
                    self.beginDiscoverServices(on: peripheral, reason: "user-pairing-watchdog")
                    self.startConnectWatchdog(for: peripheral)
                    return
                }
                // 非配对自动连接：一次 watchdog 超时即算一次完整连接失败。
                // 初次连接 + 一次软 GATT 重建后停在“点击重试”，不在单轮内每 15 秒无限发现服务。
                self.connectLog(
                    "connect watchdog: GATT pipeline timed out",
                    detail: "discoveryAttempt=\(self.gattDiscoveryAttempt) recoveryAttempt=\(self.standingConnectRecoveryCount)/\(self.maxStandingConnectRecoveryAttempts)"
                )
                self.failOrRecoverConnectionPipeline(
                    peripheral,
                    reason: "gatt-pipeline-timeout",
                    message: L10n.t("连接超时，请点击重试", "Connection timed out. Tap to retry")
                )
                return
            }

            if isStandingConnect {
                // Only a claim with previously observed BLE transport reaches this
                // timeout. An unreachable bound target keeps its native request.
                if self.freshlyRetrievedSystemConnectedPeripheral(matching: peripheral.identifier) == nil {
                    self.recordBoundBLEAttemptFailure()
                    self.systemTransportConnectedPeripheralIDs.remove(peripheral.identifier)
                    self.standingConnectPeripheralID = nil
                    self.resetConnectionHandles()
                    self.updateState(.failed(L10n.t("蓝牙连接超时", "Bluetooth connection timed out")))
                    self.connectLog("bound BLE connection attempt timed out", detail: "id=\(peripheral.identifier.uuidString) failedAttempts=\(self.boundBLEReconnectPolicy.failedAttempts) nextRecovery=exact_UUID_scan")
                    if self.stopBoundReconnectIfExhausted() { return }
                    self.centralManager.cancelPeripheralConnection(peripheral)
                    self.startSystemReconnectMonitor()
                    return
                }
                self.connectLog(
                    "standing connect stuck; rebuild GATT",
                    detail: "id=\(peripheral.identifier.uuidString) peripheralState=\(self.peripheralStateDescription(peripheral.state))"
                )
                if self.failManualHardReconnectIfNeeded(
                    for: peripheral,
                    reason: "standing-connect-timeout"
                ) {
                    return
                }
                self.beginAutomaticGATTRecovery(for: peripheral, reason: "standing-connect-timeout")
                return
            }

            // 仍未完成 GATT 发现：取消挂起请求，改挂 iOS 常驻 connect，等系统自动连上再试
            print("\(self.logTag) connect watchdog: still not connected, hand off to system auto-connect")
            self.connectLog("connect watchdog: still not connected, hand off to system auto-connect")
            if self.isUserInitiatedPairingConnect && self.isPairingSessionActive {
                self.retryUserPairingConnect(reason: "connect watchdog timeout")
                return
            }
            let wasManualReconnect = self.isManualReconnectConnect
            self.isManualReconnectConnect = false
            if !wasManualReconnect, self.canAutomaticallyRecoverGATT {
                self.beginAutomaticGATTRecovery(for: peripheral, reason: "connect-timeout")
                return
            }
            self.centralManager.cancelPeripheralConnection(peripheral)
            self.hasStartedConnect = false
            self.isBatteryRefreshMode = false
            // 用户点卡片触发的重连要给出明确失败，不能静默回到「设备未连接」。
            if wasManualReconnect {
                self.lastManualReconnectFailure = .connectFailed
            }
            self.updateState(wasManualReconnect ? .failed(L10n.t("设备连接失败", "Connection failed")) : .disconnected)
        }
        connectWatchdogWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func enqueueProbeCandidate(_ peripheral: CBPeripheral, rssi: NSNumber) {
        let value = rssi.intValue
        guard value >= minProbeRSSI else { return }
        guard !probedIDs.contains(peripheral.identifier) else { return }
        guard !discoveredPeripherals.keys.contains(peripheral.identifier) else { return }
        guard !probeCandidates.contains(where: { $0.peripheral.identifier == peripheral.identifier }) else { return }

        let candidate = ProbeCandidate(peripheral: peripheral, rssi: value)
        if isManualPairingScan, shouldPrioritizeProbe(peripheral) {
            probeCandidates.insert(candidate, at: 0)
        } else {
            probeCandidates.append(candidate)
            probeCandidates.sort { $0.rssi > $1.rssi }
        }
        print("\(logTag) probe candidate \(peripheral.identifier.uuidString) rssi=\(value), queue=\(probeCandidates.count)")
    }

    private func nameMatchesPairingModelName(
        _ peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> Bool {
        guard let modelName = pairingModelNameFilter,
              !modelName.isEmpty else {
            return false
        }

        let name = resolvedName(for: peripheral, advertisementData: advertisementData)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }

        if name.localizedCaseInsensitiveContains(modelName) { return true }
        let selected = GlassDeviceModel(modelName: modelName)
        if selected == .luminaL1 {
            return DeviceGeneration.fromDeviceName(name) == .gen1G5K61
        }
        return false
    }

    private func registerNameMatchedPairingDevice(
        _ peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        let name = resolvedName(for: peripheral, advertisementData: advertisementData)
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { return }
        addVerifiedPairingDevice(
            peripheral,
            displayName: displayName,
            rssi: rssi.intValue
        )
    }

    private func shouldPrioritizeProbe(_ peripheral: CBPeripheral) -> Bool {
        guard let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return false
        }
        if let modelName = pairingModelNameFilter, !modelName.isEmpty {
            if name.localizedCaseInsensitiveContains(modelName) { return true }
        }
        let upper = name.uppercased()
        return upper.contains("G5T71") || upper.hasPrefix("L1")
    }

    private func startProbingIfNeeded() {
        guard case .scanning = connectionState, !hasStartedConnect else { return }
        guard !shouldPauseBackgroundProbe() else {
            print("\(logTag) skip probing: verified devices already in list")
            return
        }
        guard !probeCandidates.isEmpty else {
            print("\(logTag) no probe candidates yet")
            return
        }
        print("\(logTag) start service probing, candidates=\(probeCandidates.count)")
        probeNextCandidate()
    }

    private func probeNextCandidate() {
        // 已在连接正式目标时不再探测
        guard !hasStartedConnect || isProbingService else { return }
        guard case .scanning = connectionState else { return }
        guard !shouldPauseBackgroundProbe() else { return }

        while let candidate = probeCandidates.first {
            probeCandidates.removeFirst()
            if probedIDs.contains(candidate.peripheral.identifier) { continue }
            probedIDs.insert(candidate.peripheral.identifier)
            activeProbeRSSI = candidate.rssi
            connect(to: candidate.peripheral, probing: true)
            return
        }

        print("\(logTag) probe queue empty, keep scanning")
    }

    private func handleProbeFailed(reason: String) {
        print("\(logTag) probe failed: \(reason)")
        if isUserInitiatedPairingConnect { return }
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        resetConnectionHandles()
        updateState(.scanning)

        // 继续扫，并探测下一个候选
        if !centralManager.isScanning {
            centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        guard !shouldPauseBackgroundProbe() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.probeNextCandidate()
        }
    }

    private func markReadyIfNeeded() {
        guard isServiceDiscovered, isProtocolNotificationEnabled else { return }
        guard case .ready = connectionState else {
            let awaitingSystemPairing = isUserInitiatedPairingConnect
            let wasBatteryRefresh = isBatteryRefreshMode
            isManualHardReconnectAttemptInProgress = false
            pendingManualHardReconnectPeripheralID = nil
            manualHardReconnectLookupWorkItem?.cancel()
            manualHardReconnectLookupWorkItem = nil
            clearManualHardReconnectRequirement(reason: "BLE ready")
            prepareBatteryForFreshRead()
            updateState(.ready)
            if let id = connectedPeripheral?.identifier {
                savePeripheralID(id)
            }
            if let peripheral = connectedPeripheral {
                // 已连上只保留重连身份。不要对 ready 外设再次 connect；
                // 真正掉线后由 didDisconnect / 系统连接事件启动下一轮。
                reconnectPeripheral = peripheral
                standingConnectAllowed = true
                standingConnectPeripheralID = nil
            }
            print("\(logTag) ===== BLE READY =====")
            connectLog(
                "===== BLE READY =====",
                detail: "id=\(connectedPeripheral?.identifier.uuidString ?? "nil") write=\(writeCharacteristic?.uuid.uuidString ?? "nil") notify=\(notifyCharacteristic?.uuid.uuidString ?? "nil") awaitingSystemPairing=\(awaitingSystemPairing)"
            )
            print("\(logTag) writeCharacteristic: \(writeCharacteristic?.uuid.uuidString ?? "nil")")
            print("\(logTag) notifyCharacteristic: \(notifyCharacteristic?.uuid.uuidString ?? "nil")")
            // 成功连接后允许断线交给 iOS 常驻 connect 自动连回
            autoReconnectEnabled = true
            userInitiatedDisconnect = false
            isBatteryRefreshMode = false
            reconnectPeripheral = connectedPeripheral

            let deviceInfoReadyDelay = awaitingSystemPairing ? systemPairingGraceSeconds : 2.5
            if awaitingSystemPairing {
                statusMessage = L10n.t("请在系统弹窗中完成蓝牙配对...", "Complete Bluetooth pairing in the system alert...")
                print("\(logTag) waiting \(deviceInfoReadyDelay)s for iOS system Bluetooth pairing")
            }

            // 首页电量刷新 / 系统自动连回：仅当同一外设且身份仍有效时跳过 getdevinfo。
            if wasBatteryRefresh {
                let samePeripheral = connectedPeripheral?.identifier == identityPeripheralID
                let alreadyBound = isDeviceInfoReady && samePeripheral
                identityPeripheralID = connectedPeripheral?.identifier
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self else { return }
                    if alreadyBound {
                        // getdevstat 由进入 ready 统一调度；这里只刷电量/待导入。
                        if self.isAIVisionTransferBusy {
                            self.deferredBatteryQuery = true
                            self.deferredPendingImportQuery = true
                            print("\(self.logTag) post-connect refresh deferred: AI vision transfer busy")
                        } else {
                            self.scheduleRoutineDeviceRefresh()
                        }
                    } else {
                        self.statusMessage = L10n.t("正在读取设备信息...", "Reading device info...")
                        self.queryInitialDeviceInfo()
                        DispatchQueue.main.asyncAfter(deadline: .now() + deviceInfoReadyDelay) {
                            self.markDeviceInfoReadyIfNeeded(force: true)
                        }
                    }
                }
                return
            }

            identityPeripheralID = connectedPeripheral?.identifier
            if !awaitingSystemPairing {
                statusMessage = L10n.t("正在读取设备信息...", "Reading device info...")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.queryInitialDeviceInfo()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + deviceInfoReadyDelay) { [weak self] in
                self?.markDeviceInfoReadyIfNeeded(force: true)
            }
            return
        }

        // 已 ready：不再重复 getdevstat（由进入 ready 时统一发一次 + 有限重试）。
    }

    private func queryInitialDeviceInfo() {
        // 取消上一轮未发出的定时包，避免 recover + markReady + ensureConnected 叠成指令风暴。
        initialDeviceInfoQueryGeneration += 1
        let generation = initialDeviceInfoQueryGeneration
        isInitialDeviceInfoQueryInProgress = true

        // 连接就绪后主动查询基础信息及版本，Gen2按 Android 的 3 秒间隔发送。
        let firstGeneration = deviceGeneration == .gen1G5K61
        let interval = firstGeneration ? 0.35 : Self.gen2GetDevInfoSendIntervalSeconds
        let types: [AstraA1BleProtocol.DevInfoType] = firstGeneration
            ? [.sn, .name, .model, .storage, .version2800, .version6350, .battery]
            : [.battery, .name, .model, .sn, .version2800, .version6350]
        for (index, type) in types.enumerated() {
            let delay = Double(index) * interval
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.initialDeviceInfoQueryGeneration == generation else {
                    print("\(self.logTag) queryInitialDeviceInfo cancelled type=\(type.rawValue)")
                    return
                }
                let sent = self.sendCommand(AstraA1BleProtocol.buildGetDevInfoCommand(type: type))
                self.connectLog("initial device info query", detail: "generation=\(generation) type=\(type.rawValue) key=\(AstraA1BleProtocol.devInfoKey(for: type)) sent=\(sent) target=\(self.deviceBluetoothIdentifier ?? "nil")")
            }
        }
        let extraCommands: [UInt8] = firstGeneration ? [Gen1Commands.systemName, Gen1Commands.bleMac] : []
        for (index, command) in extraCommands.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(types.count + index) * interval) { [weak self] in
                guard let self, self.initialDeviceInfoQueryGeneration == generation else { return }
                _ = self.sendGen1Command(command: command)
            }
        }
        let pendingDelay = Double(types.count + extraCommands.count) * interval
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingDelay) { [weak self] in
            guard let self else { return }
            guard self.initialDeviceInfoQueryGeneration == generation else { return }
            self.isInitialDeviceInfoQueryInProgress = false
            // Gen2 SN 在约 9 秒才发出，早先的 2.5 秒身份检查可能尚未收到 SN。
            self.markDeviceInfoReadyIfNeeded(force: true)
            if self.isQueryingDeviceVersionsAndStorage {
                self.sendNextVersionsAndStorageQuery()
            } else if self.isQueryingAboutDeviceInfo {
                self.sendNextAboutDeviceInfoQuery()
            }
            self.queryUpgradeDeviceInfo()
            if self.isAIVisionTransferBusy {
                self.deferredPendingImportQuery = true
                print("\(self.logTag) initial hasnewfile deferred: AI vision transfer busy")
                self.runDeferredBatteryQueryIfNeeded()
                return
            }
            self.queryPendingImportFiles()
            self.runDeferredRoutineQueriesIfNeeded()
            // 对齐 Android 连接就绪后的连续对话时长查询；
            // 放在 getdevinfo 队列之后，避免敏感固件收到并发命令。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                _ = self?.queryAIVoiceListeningDuration()
            }
        }
        print("\(logTag) queryInitialDeviceInfo scheduled gen=\(generation) count=\(types.count) interval=\(interval)s")
    }

    private func cancelInitialDeviceInfoQuery(reason: String) {
        if isInitialDeviceInfoQueryInProgress || initialDeviceInfoQueryGeneration > 0 {
            print("\(logTag) cancelInitialDeviceInfoQuery reason=\(reason) gen=\(initialDeviceInfoQueryGeneration)")
        }
        initialDeviceInfoQueryGeneration += 1
        isInitialDeviceInfoQueryInProgress = false
    }

    private func handleNotifyData(_ data: Data) {
        let frames = AstraNotificationFramer.frames(in: data)
        if frames.count > 1 {
            print("\(logTag) split notification bytes=\(data.count) frames=\(frames.count)")
        }
        for frame in frames {
            handleSingleNotifyFrame(frame)
        }
    }

    private func handleSingleNotifyFrame(_ data: Data) {
        guard let command = AstraA1BleProtocol.parseCommandHeader(from: data) else {
            print("\(logTag) notify data (\(data.count) bytes): header parse failed")
            return
        }

        // These control replies return before the general packet logger below. Keep
        // them in exported logs so missing UI state can be distinguished from a lost ACK.
        if ["wakeuprsp0", "aivsilrsp0", "trslatests", "guideevt00", "aivoicests"].contains(command) {
            DebugLogStore.logBLEReceived(data)
        }

        // 识图大数据包：对齐安卓，只记长度/命令，禁止整包 hex（主线程打满会拖垮收包）。
        if command == "imgrecdata" || command == "imgrecrsp0" {
            print("\(logTag) notify command=\(command) bytes=\(data.count)")
            aiVisionNotifyHandler?(command, data)
            return
        }

        if command == "aivoicests" || command == "aivoicedat" || command == "aivoicetur" {
            print("\(logTag) notify command=\(command) bytes=\(data.count)")
            aiVoiceNotifyHandler?(command, data)
            return
        }

        if command == "aivsilrsp0" {
            if let response = AstraA1BleProtocol.parseAIVoiceListeningDurationResponse(data) {
                voiceSettingsResponseSequence += 1
                aiVoiceListeningDurationResponse = AIVoiceListeningDurationResponse(
                    status: response.status,
                    seconds: response.seconds,
                    sequence: voiceSettingsResponseSequence
                )
                print("\(logTag) aivsilrsp0 status=\(response.status) seconds=\(response.seconds)")
            } else {
                print("\(logTag) aivsilrsp0 parse failed bytes=\(data.count)")
            }
            return
        }

        if command == "wakeuprsp0" {
            if let response = AstraA1BleProtocol.parseVoiceWakeupResponse(data) {
                voiceSettingsResponseSequence += 1
                voiceWakeupResponse = VoiceWakeupResponse(
                    status: response.status,
                    enabled: response.enabled,
                    sequence: voiceSettingsResponseSequence
                )
                print("\(logTag) wakeuprsp0 status=\(response.status) enabled=\(response.enabled)")
            } else {
                print("\(logTag) wakeuprsp0 parse failed bytes=\(data.count)")
            }
            return
        }

        if command == "trslatests" || command == "trslatedat" {
            print("\(logTag) notify command=\(command) bytes=\(data.count)")
            translationVoiceNotifyHandler?(command, data)
            return
        }

        if command == "guideevt00" {
            if let eventType = AstraA1BleProtocol.parseGuideEvent(data) {
                print("\(logTag) guideevt00 event=\(eventType)")
                guideEventHandler?(eventType)
            } else {
                print("\(logTag) guideevt00 parse failed bytes=\(data.count)")
            }
            return
        }

        let preview = data.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
        print("\(logTag) notify data (\(data.count) bytes): \(preview)\(data.count > 24 ? " ..." : "")")
        DebugLogStore.logBLEReceived(data)
        print("\(logTag) notify command=\(command)")

        if command == "ledbrirsp0" {
            guard deviceGeneration == .gen2, isReady else { return }
            guard let response = Gen2IndicatorBrightnessProtocol.parseResponse(data) else {
                DebugLogStore.logBLEEvent("indicator brightness invalid response", detail: "bytes=\(data.count)")
                return
            }
            if indicatorBrightness.receive(response) {
                indicatorBrightnessTask?.cancel()
                indicatorBrightnessTask = nil
                DebugLogStore.logBLEEvent("indicator brightness confirmed",
                    detail: "status=\(response.status) actualLevel=\(response.level.rawValue)")
            }
            return
        }

        // Gen2连接启用通知后即上报一次，插拔充电器时继续上报。
        // 独立更新 Published 状态，让首页在电量百分比不变时也立即切换充电图标。
        if command == "chargestat" {
            guard deviceGeneration == .gen2 else { return }
            if let response = AstraA1BleProtocol.parseChargingStateNotify(data) {
                deviceIsCharging = response.isCharging
                print("\(logTag) chargestat state=\(response.state) charging=\(response.isCharging)")
            } else {
                print("\(logTag) chargestat parse failed bytes=\(data.count)")
            }
            return
        }

        // 眼镜连上后首包电量走 getdevinfo batt0，之后约每 2 分钟主动上报 batteryntf。
        if command == "batteryntf" {
            if let level = AstraA1BleProtocol.parseBatteryNotify(data) {
                applyBatteryPercent(level, source: "batteryntf")
                markDeviceInfoReadyIfNeeded(force: false)
                // 上报即视为一次有效刷新，重新计时，避免刚上报又立刻主动查。
                scheduleNextBatteryPoll(after: batteryPollingInterval)
            } else {
                print("\(logTag) batteryntf parse failed bytes=\(data.count)")
            }
            return
        }

        if command == "devstatus0" {
            if let status = AstraA1BleProtocol.parseDevStatus(data) {
                print("[device_status] recv devstatus0 \(status.logDescription)")
                applyDeviceRuntimeStatus(status, source: "devstatus0", receivedFromDevice: true)
            } else {
                print("[device_status] recv devstatus0 parse failed raw=\(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
            return
        }

        if command == "actionrsp0" {
            if let response = AstraA1BleProtocol.parseActionResponse(data) {
                print("[device_status] recv actionrsp0 action=\(response.action.rawValue) result=\(response.rawResult) current=\(response.currentStatus.logDescription)")
                handleActionResponse(response)
            } else {
                print("[device_status] recv actionrsp0 parse failed raw=\(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
            return
        }

        if command == "eqmodersp0" {
            if let response = AstraA1BleProtocol.parseEQModeResponse(data) {
                applySoundEffectResponse(status: response.status, mode: response.mode)
            } else {
                print("\(logTag) eqmodersp0 parse failed bytes=\(data.count)")
            }
            return
        }

        if command == "vidresrsp0" {
            if let response = AstraA1BleProtocol.parseVideoResolutionResponse(data) {
                settingsVideoResolutionProfile = response.profile
                print("\(logTag) vidresrsp0 status=\(response.status) profile=\(response.profile)")
            }
            return
        }

        if command == "weardetrsp" {
            if let response = AstraA1BleProtocol.parseWearDetectionResponse(data) {
                settingsWearDetectionEnabled = response.enabled
                print("\(logTag) weardetrsp result=\(response.result) enabled=\(response.enabled)")
            }
            return
        }

        if command == "testresult" {
            if let response = AstraA1BleProtocol.parseFactoryResetResponse(data), response.testID == 0x13 {
                if deviceGeneration == .gen2, response.result == 1, unpairFactoryResetConfirmation == nil {
                    resetIndicatorBrightness()
                    scheduleIndicatorBrightnessQuery()
                }
                if var confirmation = unpairFactoryResetConfirmation {
                    let accepted = confirmation.receive(response.result, from: connectedPeripheral?.identifier, now: ProcessInfo.processInfo.systemUptime)
                    unpairFactoryResetConfirmation = confirmation
                    connectLog("unbind: factory reset response", detail: "result=\(response.result) accepted=\(accepted) target=\(confirmation.targetID.uuidString)")
                } else {
                    factoryResetResult = response.result
                }
                print("\(logTag) factory testresult=\(response.result)")
            }
            return
        }

        if command == "hasnewfile",
           let info = AstraA1BleProtocol.parseHasNewFileResponse(data) {
            if info.fileType == 1 {
                let count = info.hasNew ? max(0, info.fileCount) : 0
                // 本地仍有删除残留时，勿被「count=0」冲掉导入条。
                let leftover = AIRecordingImportManager.shared.leftoverDeviceFileCount
                if count == 0, leftover > 0 {
                    pendingRecordingImportFileCount = leftover
                    print("\(logTag) hasnewfile recording count=0 but keep leftover=\(leftover)")
                } else {
                    pendingRecordingImportFileCount = count
                }
                persistPendingRecordingCount(pendingRecordingImportFileCount)
                if info.hasNew {
                    isAIRecording = false
                    finishRuntimeOperationIfNeeded(
                        expected: .voiceRecording,
                        fallback: .unknown,
                        reason: "ai-record-file-ready"
                    )
                }
                print("\(logTag) hasnewfile recording hasNew=\(info.hasNew) fileCount=\(info.fileCount) pendingRecording=\(pendingRecordingImportFileCount)")
            } else {
                pendingImportFileCount = info.hasNew ? max(0, info.fileCount) : 0
                print("\(logTag) hasnewfile media hasNew=\(info.hasNew) fileCount=\(info.fileCount) pending=\(pendingImportFileCount)")
                if isTakingPhoto {
                    logPhotoCapture("files-reported", detail: "hasNew=\(info.hasNew) count=\(info.fileCount) increased=\(pendingImportFileCount > homePhotoBaselineCount)")
                    // Existing files alone cannot confirm this photo request.
                    if info.hasNew, homePhotoObservedTaking,
                       pendingImportFileCount > homePhotoBaselineCount {
                        finishPhotoCaptureSuccess(evidence: "photo_taking_and_file_count_increased")
                    }
                }
                if info.hasNew, isVideoStopping {
                    // Counts may describe an older photo/video; they do not confirm this stop.
                    logVideoCapture("files-reported", detail: "count=\(info.fileCount) action=query_status completion=false")
                    forceQueryDeviceStatus(reason: "video-files-reported")
                }
                if info.hasNew, let cont = mediaCaptureContinuation {
                    mediaCaptureContinuation = nil
                    cont.resume()
                }
            }
            return
        }

        if command == "wificonfig" {
            let preview = data.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("\(logTag) wificonfig raw (\(data.count) bytes): \(preview)\(data.count > 24 ? " ..." : "")")
            wifiLog(
                "收到 wificonfig 数据",
                detail: "bytes=\(data.count)\ndeclaredPayload=\(AstraA1BleProtocol.declaredPayloadLength(data) ?? -1)\n\(WifiConnectionDiagnostics.credentialFields(in: data))",
                direction: .received
            )
            if AstraA1BleProtocol.isTruncatedPacket(data) {
                let declared = AstraA1BleProtocol.declaredPayloadLength(data) ?? -1
                // 命中缓存的快速路径（无 wifiConfigContinuation）不关心 wificonfig 内容，
                // 不必发起 read 兜底，避免无谓的“request not supported”噪音。
                if wifiConfigContinuation != nil {
                    print("\(logTag) wificonfig truncated: received=\(data.count) declaredPayload=\(declared), reading notify char...")
                    wifiLog(
                        "wificonfig 数据被截断，尝试主动读取",
                        detail: "received=\(data.count)\ndeclaredPayload=\(declared)",
                        direction: .received
                    )
                    requestFullNotifyPayload(for: command)
                } else {
                    print("\(logTag) wificonfig truncated (no waiter): received=\(data.count) declaredPayload=\(declared), ignored")
                    wifiLog(
                        "wificonfig 数据被截断且当前无等待任务",
                        detail: "received=\(data.count)\ndeclaredPayload=\(declared)",
                        direction: .received
                    )
                }
                return
            }
            notifyReadAttempts = 0
            if let config = AstraA1BleProtocol.parseWifiConfig(data),
               let ssid = config.ssid?.trimmingCharacters(in: .whitespacesAndNewlines), !ssid.isEmpty {
                print("\(logTag) wificonfig ssid=\(ssid) passwordEmpty=\((config.password ?? "").isEmpty) http=\(config.httpAddress ?? "<nil>")")
                wifiLog(
                    "wificonfig 解析成功",
                    detail: "ssid=\(ssid)\nparsedSSID=\(config.ssid?.debugDescription ?? "nil")\nparsedPassword=\(config.password?.debugDescription ?? "nil")\npasswordUTF8Bytes=\(config.password?.utf8.count ?? 0)\npasswordEmpty=\((config.password ?? "").isEmpty)\nhttp=\(config.httpAddress ?? "nil")",
                    direction: .received
                )
                cacheWifiCredentialIfPossible(config)
                if let cont = wifiConfigContinuation {
                    wifiConfigContinuation = nil
                    cont.resume(returning: config)
                }
            } else if let cont = wifiConfigContinuation {
                wifiConfigContinuation = nil
                wifiLog(
                    "wificonfig 解析失败",
                    detail: "bytes=\(data.count)\ndeclaredPayload=\(AstraA1BleProtocol.declaredPayloadLength(data) ?? -1)",
                    direction: .received
                )
                cont.resume(throwing: ImportBLEError.failed(L10n.t("Wi-Fi 配置解析失败", "Failed to parse Wi-Fi config")))
            }
            return
        }

        if command == "getworkpat" {
            if AstraA1BleProtocol.isTruncatedPacket(data) {
                let declared = AstraA1BleProtocol.declaredPayloadLength(data) ?? -1
                if workPathContinuation != nil {
                    print("\(logTag) getworkpat truncated: received=\(data.count) declaredPayload=\(declared), reading notify char...")
                    requestFullNotifyPayload(for: command)
                } else {
                    print("\(logTag) getworkpat truncated (no waiter): received=\(data.count) declaredPayload=\(declared), ignored")
                }
                return
            }
            notifyReadAttempts = 0
            if let url = AstraA1BleProtocol.parseGetWorkPathResponse(data) {
                print("\(logTag) getworkpat url=\(url)")
                if let cont = workPathContinuation {
                    workPathContinuation = nil
                    cont.resume(returning: url)
                }
            } else if let cont = workPathContinuation {
                workPathContinuation = nil
                cont.resume(throwing: ImportBLEError.failed(L10n.t("HTTP 路径解析失败", "Failed to parse HTTP path")))
            }
            return
        }

        if command == "getalgoinf" {
            if AstraA1BleProtocol.isTruncatedPacket(data) {
                let declared = AstraA1BleProtocol.declaredPayloadLength(data) ?? -1
                if algorithmInfoContinuation != nil {
                    print("\(logTag) getalgoinf truncated: received=\(data.count) declaredPayload=\(declared), reading notify char...")
                    requestFullNotifyPayload(for: command)
                }
                return
            }
            notifyReadAttempts = 0
            if let info = AstraA1BleProtocol.parseAlgorithmInfoResponse(data) {
                print("\(logTag) getalgoinf count=\(info.count)")
                if let cont = algorithmInfoContinuation {
                    algorithmInfoContinuation = nil
                    cont.resume(returning: info)
                }
            } else if let cont = algorithmInfoContinuation {
                algorithmInfoContinuation = nil
                cont.resume(throwing: ImportBLEError.failed(
                    L10n.t("算法文件信息解析失败", "Failed to parse algorithm file information")
                ))
            }
            return
        }

        if command == "dllprogres" {
            if let percent = AstraA1BleProtocol.parseDLLProgress(data) {
                print("\(logTag) dllprogres percent=\(percent)")
                dllProgressHandler?(percent)
            }
            return
        }

        if command == "dllupdrsp0" {
            guard let result = AstraA1BleProtocol.parseDLLUpdateResult(data) else {
                print("\(logTag) dllupdrsp0 parse failed bytes=\(data.count)")
                return
            }
            print("\(logTag) dllupdrsp0 status=\(result.status) done=\(result.doneCount) failID=\(result.failID)")
            // Android defines 1=OK, 2/4/5/6=terminal failures. BUSY(3) and
            // unknown statuses do not establish that device-side writes stopped.
            if [1, 2, 4, 5, 6].contains(result.status), let id = connectedPeripheral?.identifier {
                gen2OtaRecovery.markAlgorithmInstallFinished(from: id)
            }
            if let cont = dllUpdateContinuation {
                dllUpdateContinuation = nil
                dllProgressHandler = nil
                cont.resume(returning: result)
            }
            return
        }

        if command == "toopenwifi" || command == "closewifi" || command == "closewifi0"
            || command == "deletefile"
            || command == "takephoto0" || command == "startvideo" || command == "stopvideo0" {
            let isGen1Close = deviceGeneration == .gen1G5K61 && (command == "closewifi" || command == "closewifi0")
            let ok = isGen1Close ? (data.count == 13 && data[10] == 1 && data[11] == 0 && data[12] == 0)
                : (AstraA1BleProtocol.parseStatusResponse(data) ?? false)
            if command == "toopenwifi", ok, isFirmwareUpgradeFlowBusy,
               wifiConfigContinuation != nil || statusContinuationCommand == "toopenwifi",
               deviceGeneration == .gen2, let id = connectedPeripheral?.identifier {
                if gen2OtaRecovery.acceptPreparation(from: id) {
                    wifiLog("本次 OTA 准备已被设备接受", detail: "peripheral=\(id)", direction: .received)
                }
            }
            print("\(logTag) \(command) status=\(ok)")
            if command == "toopenwifi" || command == "closewifi" || command == "closewifi0" {
                wifiLog(
                    "收到 \(command) 状态",
                    detail: "success=\(ok)\nbytes=\(data.count)",
                    direction: .received
                )
            }
            // toopenwifi 失败时设备不会再发 wificonfig，直接失败，别白等 15s（对齐安卓快速失败）。
            if command == "toopenwifi", !ok, let cont = wifiConfigContinuation {
                wifiConfigContinuation = nil
                cont.resume(throwing: ImportBLEError.openWifiRejected)
                return
            }
            let matched = statusContinuationAliases.contains(command)
                || statusContinuationCommand == command
            if matched, let cont = statusContinuation {
                statusContinuation = nil
                statusContinuationCommand = nil
                statusContinuationAliases = []
                cont.resume(returning: ok)
            }
            return
        }

        if command == "otaprogres" || command.hasPrefix("otaprogre") {
            // 对齐安卓：命令头可能被截成 otaprogre（无末尾 s）。
            if let percent = AstraA1BleProtocol.parseOtaProgress(data) {
                print("\(logTag) otaprogres cmd=\(command) percent=\(percent)")
                completeOtaUpgradeIfNeeded(percent: percent)
            } else {
                print("\(logTag) otaprogres parse failed cmd=\(command) bytes=\(data.count)")
            }
            return
        }

        if command == "getdevinfo" {
            if AstraA1BleProtocol.isTruncatedPacket(data) {
                let declared = AstraA1BleProtocol.declaredPayloadLength(data) ?? -1
                let key = data.count >= 17 ? String(decoding: data[12..<17], as: UTF8.self) : "unknown"
                DebugLogStore.logBLEEvent(
                    "getdevinfo incomplete",
                    detail: "key=\(key) receivedBytes=\(data.count) expectedBytes=\(12 + declared) missingBytes=\(max(0, 12 + declared - data.count)) next=read-fallback; raw callbacks determine whether continuation arrived"
                )
                requestFullNotifyPayload(for: command)
                // ver28 等长包截断后要读完整特征：延长当前串行步骤超时。
                if isQueryingDeviceVersionsAndStorage, let type = versionsStoragePendingTypes.first {
                    armVersionsAndStorageTimeout(for: type)
                }
                if isQueryingAboutDeviceInfo, let type = aboutDeviceInfoPendingTypes.first {
                    armAboutDeviceInfoTimeout(for: type)
                }
                return
            }
            guard let result = AstraA1BleProtocol.parseGetDevInfoResponse(data) else {
                let declaredLen = data.count >= 12 ? Int(data[10]) | (Int(data[11]) << 8) : -1
                DebugLogStore.logBLEEvent("getdevinfo parse failed", detail: "receivedBytes=\(data.count) declaredPayload=\(declaredLen)")
                if isQueryingAboutDeviceInfo {
                    finishAboutDeviceInfoQueryStep()
                }
                if isQueryingDeviceVersionsAndStorage {
                    finishVersionsAndStorageQueryStep()
                }
                return
            }
            print("\(logTag) getdevinfo key=\(result.key) value=\(result.value)")
            applyGetDevInfoResult(result)
            if isQueryingAboutDeviceInfo,
               let pending = aboutDeviceInfoPendingTypes.first,
               result.key == AstraA1BleProtocol.devInfoKey(for: pending) {
                finishAboutDeviceInfoQueryStep()
            } else if isQueryingAboutDeviceInfo {
                print("\(logTag) queryAboutDeviceInfo ignored key=\(result.key) waiting=\(AstraA1BleProtocol.devInfoKey(for: aboutDeviceInfoPendingTypes.first ?? .name))")
            }
            if isQueryingDeviceVersionsAndStorage,
               let pending = versionsStoragePendingTypes.first,
               result.key == AstraA1BleProtocol.devInfoKey(for: pending) {
                finishVersionsAndStorageQueryStep()
            } else if isQueryingDeviceVersionsAndStorage {
                print("\(logTag) refreshDeviceVersionsAndStorage ignored key=\(result.key) waiting=\(AstraA1BleProtocol.devInfoKey(for: versionsStoragePendingTypes.first ?? .storage))")
            }
        }
    }

    private func applyGetDevInfoResult(_ result: (key: String, value: String, rawValue: Data)) {
        if deviceGeneration == .gen2, ["ver28", "ver63"].contains(result.key),
           let targetID = connectedPeripheral?.identifier {
            gen2OtaVersionReportSequence += 1
            gen2OtaVersionReports[result.key] = Gen2OtaVersionReport(targetID: targetID, version: result.value, sequence: gen2OtaVersionReportSequence)
            if isFirmwareUpgradeFlowBusy {
                wifiLog("升级：收到设备版本", detail: "target=\(targetID) key=\(result.key) value=\(result.value) sequence=\(gen2OtaVersionReportSequence)", direction: .received)
            }
        }
        defer {
            // A delayed, complete response may still recover a previously failed query.
            if cachedValue(for: .version2800) != nil, cachedValue(for: .version6350) != nil {
                deviceVersionQueryFailed = false
            }
        }
        switch result.key {
        case "name0":
            deviceName = result.value
        case "model":
            deviceModel = result.value
        case "sn000":
            deviceSN = result.value
        case "stor0":
            deviceStorage = result.value
        case "ver28":
            // Reconcile interrupted OTA only from a newly received reply. Never
            // clear recovery from cached versions, another device, or SDK success.
            if deviceGeneration == .gen1G5K61, !isFirmwareUpgradeFlowBusy,
               let targetID = connectedPeripheral?.identifier, savedPeripheralID() == targetID,
               Gen1BluetoothOtaRecoveryStore().clearAfterVersionConfirmation(
                   targetID: targetID, actualVersion: result.value, accountID: gen1ImportAccount(for: targetID)
               ) {
                DebugLogStore.logBLEEvent("Gen1 Bluetooth OTA recovery version confirmed",
                    detail: "target=\(targetID) actualVersion=\(result.value) markerCleared=true source=fresh_normal_service_reply")
            }
            deviceVersion2800 = result.value
        case "ver63":
            deviceVersion6350 = result.value
        case "batt0":
            let battery = AstraA1BleProtocol.parseBatteryValue(result.value, rawValue: result.rawValue)
            if let percent = battery.percent {
                applyBatteryPercent(percent, source: "getdevinfo batt0")
            } else if !result.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      result.value.uppercased() != "N/A" {
                deviceBattery = result.value
                isBatteryLevelKnown = true
            }
            print("\(logTag) battery percent=\(battery.percent.map(String.init) ?? "nil") charging=\(deviceIsCharging) raw=\(result.value)")
        default:
            break
        }
        markDeviceInfoReadyIfNeeded(force: false)
    }

    /// 绑定前至少要有设备名 / 型号 / SN；SN 不能用 UUID 顶替（UUID 单独作 serial_number）。
    private func markDeviceInfoReadyIfNeeded(force: Bool) {
        guard !isDeviceInfoReady else { return }
        let hasName = !(deviceName ?? "").isEmpty
        let hasModel = !(deviceModel ?? "").isEmpty
        let hasSN = !(deviceSN ?? "").isEmpty
        if (hasName && hasModel && hasSN) || (force && hasSN) {
            if (deviceName ?? "").isEmpty {
                deviceName = connectedPeripheral?.name ?? "MOCO AI Glasses"
            }
            if (deviceModel ?? "").isEmpty {
                deviceModel = deviceGeneration == .gen1G5K61 ? "G5K61" : "Astra A1"
            }
            isDeviceInfoReady = true
            connectLog("device identity ready", detail: "peripheral=\(deviceBluetoothIdentifier ?? "nil") hasName=\(hasName) hasModel=\(hasModel) hasSN=\(hasSN)")
            // 断连后 deviceSN 会被清空，这里先落盘，保证解绑时还能拿到 sn。
            cacheHardwareSN(serialNumber: deviceBluetoothIdentifier, sn: deviceSN)
            // 首次配对（大 MTU）后按需缓存热点凭据，供后续导入直接命中，规避 MTU 截断。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.seedWifiCredentialIfNeeded()
            }
        } else if force {
            connectLog("device identity still incomplete", detail: "peripheral=\(deviceBluetoothIdentifier ?? "nil") hasName=\(hasName) hasModel=\(hasModel) hasSN=\(hasSN) readUnsupported=\(notifyReadUnsupported) readAttempts=\(notifyReadAttempts)")
        }
    }

    /// 供绑定接口使用的设备信息快照。
    /// - Parameter appModelName: 接口型号列表中的 model_name（如 G5T71），后端按此校验。
    ///
    /// 字段语义（对照后台「MAC地址」列）：
    /// - `serial_number`：蓝牙标识。Android 为真实 MAC；iOS CoreBluetooth 不暴露 MAC，传外设 UUID。
    /// - `sn`：设备 SN（getdevinfo `sn000`），如 `G5T712604R00269`。
    func bindDeviceSnapshot(appModelName: String) -> BindDeviceRequest? {
        guard isDeviceInfoReady else { return nil }
        let name = deviceName ?? appModelName
        let sn = deviceSN?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bluetoothID = connectedPeripheral?.identifier.uuidString
            ?? deviceBluetoothIdentifier

        // serial_number 必须是蓝牙标识，不能再把 SN 填进去（后台 MAC 列会显示成 SN）。
        guard let bluetoothID, !bluetoothID.isEmpty else {
            print("\(logTag) bind snapshot aborted: missing bluetooth identifier")
            return nil
        }
        guard let sn, !sn.isEmpty else {
            print("\(logTag) bind snapshot aborted: missing device SN")
            return nil
        }

        print("\(logTag) bind snapshot appModel=\(appModelName) hardwareModel=\(deviceModel ?? "nil") name=\(name) serial_number(ble)=\(bluetoothID) sn=\(sn)")
        cacheHardwareSN(serialNumber: bluetoothID, sn: sn)
        return BindDeviceRequest(
            serialNumber: bluetoothID,
            sn: sn,
            modelName: appModelName,
            deviceName: name
        )
    }

    private func resolvedName(for peripheral: CBPeripheral, advertisementData: [String: Any]) -> String {
        peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? ""
    }

    private func logDiscoveredPeripheral(
        _ peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        let id = peripheral.identifier
        guard !loggedPeripheralIDs.contains(id) else { return }
        loggedPeripheralIDs.insert(id)

        let name = resolvedName(for: peripheral, advertisementData: advertisementData)
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString)
            .joined(separator: ", ") ?? "(none)"

        print("\(logTag) ---------- SCAN DEVICE ----------")
        print("\(logTag) name: \(name.isEmpty ? "(no name)" : name)")
        print("\(logTag) identifier: \(id.uuidString)")
        print("\(logTag) rssi: \(rssi)")
        print("\(logTag) advertised services: \(serviceUUIDs)")
        print("\(logTag) hasProtocolService: \(advertisesProtocolService(advertisementData))")
        print("\(logTag) --------------------------------")
    }

    private func logAllServicesAndCharacteristics(of peripheral: CBPeripheral) {
        print("\(logTag) ========== SERVICES & CHARACTERISTICS ==========")
        print("\(logTag) peripheral: \(peripheral.name ?? "(no name)") [\(peripheral.identifier.uuidString)]")

        guard let services = peripheral.services, !services.isEmpty else {
            print("\(logTag) no services found")
            print("\(logTag) ================================================")
            return
        }

        for service in services {
            print("\(logTag) SERVICE: \(service.uuid.uuidString) isPrimary=\(service.isPrimary)")
            for characteristic in service.characteristics ?? [] {
                print("\(logTag)   CHAR: \(characteristic.uuid.uuidString)")
                print("\(logTag)     properties: \(describeProperties(characteristic.properties))")
            }
        }
        print("\(logTag) ================================================")
    }

    private func describeProperties(_ properties: CBCharacteristicProperties) -> String {
        var items: [String] = []
        if properties.contains(.broadcast) { items.append("broadcast") }
        if properties.contains(.read) { items.append("read") }
        if properties.contains(.writeWithoutResponse) { items.append("writeWithoutResponse") }
        if properties.contains(.write) { items.append("write") }
        if properties.contains(.notify) { items.append("notify") }
        if properties.contains(.indicate) { items.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { items.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties) { items.append("extendedProperties") }
        return items.isEmpty ? "none" : items.joined(separator: " | ")
    }

    private func assignCharacteristics(from services: [CBService]) {
        writeCharacteristic = nil
        notifyCharacteristic = nil
        gen1VoiceCharacteristic = nil
        if let service = services.first(where: { $0.uuid == AstraA1BleProtocol.serviceUUID }) {
            deviceGeneration = .gen2
            let chars = service.characteristics ?? []
            writeCharacteristic = chars.first { $0.uuid == AstraA1BleProtocol.writeCharacteristicUUID }
                ?? chars.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
            notifyCharacteristic = chars.first { $0.uuid == AstraA1BleProtocol.notifyCharacteristicUUID }
                ?? chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        } else if let service = services.first(where: { $0.uuid == Self.gen1ServiceUUID }) {
            deviceGeneration = .gen1G5K61
            let chars = service.characteristics ?? []
            writeCharacteristic = chars.first { $0.uuid == Self.gen1WriteUUID }
            notifyCharacteristic = chars.first { $0.uuid == Self.gen1ControlUUID }
            gen1VoiceCharacteristic = chars.first { $0.uuid == Self.gen1VoiceUUID }
        } else {
            deviceGeneration = .unknown
        }
    }

    private var protocolNotificationsReady: Bool {
        guard notifyCharacteristic?.isNotifying == true else { return false }
        return deviceGeneration != .gen1G5K61 || gen1VoiceCharacteristic?.isNotifying == true
    }

    private func subscribeProtocolNotifications(on peripheral: CBPeripheral) {
        if let notifyCharacteristic, !notifyCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: notifyCharacteristic)
        }
        if deviceGeneration == .gen1G5K61, let gen1VoiceCharacteristic, !gen1VoiceCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: gen1VoiceCharacteristic)
        }
    }

    private func beginNotificationSetup(on peripheral: CBPeripheral) {
        updateState(.enablingNotifications)
        startConnectWatchdog(for: peripheral, timeoutOverride: connectWatchdogSeconds)
        subscribeProtocolNotifications(on: peripheral)
        isProtocolNotificationEnabled = protocolNotificationsReady
        if isProtocolNotificationEnabled { markReadyIfNeeded() }
    }

    private func finishCharacteristicDiscovery(for peripheral: CBPeripheral) {
        guard pendingCharacteristicDiscoveries == 0 else { return }

        logAllServicesAndCharacteristics(of: peripheral)
        assignCharacteristics(from: peripheral.services ?? [])

        print("\(logTag) selected write=\(writeCharacteristic?.uuid.uuidString ?? "nil")")
        print("\(logTag) selected notify=\(notifyCharacteristic?.uuid.uuidString ?? "nil")")

        if writeCharacteristic == nil || notifyCharacteristic == nil || (deviceGeneration == .gen1G5K61 && gen1VoiceCharacteristic == nil) {
            if isProbingService {
                handleProbeFailed(reason: "协议服务内未找到写特征")
            } else {
                failOrRecoverConnectionPipeline(
                    peripheral,
                    reason: "write-characteristic-missing",
                    message: L10n.t("未找到写特征，请查看控制台服务/特征日志", "Write characteristic not found")
                )
            }
            return
        }

        isProbingService = false
        isServiceDiscovered = true
        beginNotificationSetup(on: peripheral)
    }
}

// MARK: - CBCentralManagerDelegate

extension AstraA1BleManager: CBCentralManagerDelegate {
    nonisolated func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        Task { @MainActor in
            guard central === centralManager else { return }
            let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            connectLog(
                "central manager restored",
                detail: "peripherals=\(peripherals.map(\.identifier.uuidString).joined(separator: ","))",
                direction: .received
            )
            guard let savedID = savedPeripheralID(),
                  let peripheral = peripherals.first(where: { $0.identifier == savedID }) else {
                return
            }

            userInitiatedDisconnect = false
            autoReconnectEnabled = true
            standingConnectAllowed = peripheral.state == .connected
            reconnectPeripheral = peripheral
            peripheral.delegate = self

            guard central.state == .poweredOn else {
                pendingBatteryRefresh = true
                return
            }
            if peripheral.state == .connected {
                systemTransportConnectedPeripheralIDs.insert(peripheral.identifier)
                attachToConnectedPeripheral(peripheral)
            } else {
                updateState(.disconnected)
                startSystemReconnectMonitor()
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard central === centralManager else { return }
            if manualHardReconnectOldCentral === central {
                connectLog(
                    "old central state ignored during hard reconnect release",
                    detail: "raw=\(central.state.rawValue)"
                )
                return
            }
            print("\(logTag) centralManagerDidUpdateState=\(central.state.rawValue)")
            connectLog("centralManagerDidUpdateState", detail: "raw=\(central.state.rawValue)", direction: .received)
            switch central.state {
            case .poweredOn:
                registerForSystemConnectionEventsIfNeeded()
                if isManualHardReconnectAttemptInProgress {
                    resumeManualHardReconnectIfPossible()
                    return
                }
                if pendingStart {
                    beginScan()
                }
                if !pendingBoundSerialNumbers.isEmpty {
                    let serials = pendingBoundSerialNumbers
                    pendingBoundSerialNumbers = []
                    print("\(logTag) bluetooth powered on, resume adopt bound peripherals")
                    connectLog("bluetooth powered on, resume adopt bound peripherals")
                    adoptBoundPeripheralIDs(serials)
                }
                if pendingBatteryRefresh {
                    print("\(logTag) bluetooth powered on, resume battery refresh")
                    connectLog("bluetooth powered on, resume battery refresh")
                    refreshBatteryLevel()
                }
                if autoReconnectEnabled, !userInitiatedDisconnect, !isReady {
                    if !attachToAlreadyConnectedPeripheralIfPossible(source: "centralPoweredOn") {
                        standingConnectAllowed = false
                        updateState(.disconnected)
                        startSystemReconnectMonitor()
                    }
                }
            case .poweredOff:
                cancelManualHardReconnectState(reason: "bluetooth powered off")
                systemTransportConnectedPeripheralIDs.removeAll()
                if let peripheral = connectedPeripheral ?? reconnectPeripheral {
                    reconnectPeripheral = peripheral
                }
                cancelAutomaticGATTRecovery(reason: "bluetooth-powered-off", resetAttempts: true)
                stopScan()
                stopSystemReconnectMonitor()
                cancelConnectWatchdog()
                cancelDiscoverServicesWorkItem()
                standingConnectPeripheralID = nil
                hasStartedConnect = false
                resetConnectionHandles()
                updateState(.bluetoothUnavailable(L10n.t("请打开手机蓝牙", "Turn on Bluetooth")))
            case .unauthorized:
                cancelManualHardReconnectState(reason: "bluetooth unauthorized")
                updateState(.bluetoothUnavailable(L10n.t("请在设置中允许蓝牙权限", "Allow Bluetooth in Settings")))
            case .unsupported:
                cancelManualHardReconnectState(reason: "bluetooth unsupported")
                updateState(.bluetoothUnavailable(L10n.t("当前设备不支持蓝牙", "Bluetooth not supported")))
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        connectionEventDidOccur event: CBConnectionEvent,
        for peripheral: CBPeripheral
    ) {
        let eventDate = Date()
        let eventUptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            guard central === centralManager else { return }
            if peerEventDiagnosticObservations.count >= 32,
               peerEventDiagnosticObservations[peripheral.identifier] == nil,
               let oldest = peerEventDiagnosticObservations.min(by: { $0.value.uptime < $1.value.uptime })?.key {
                peerEventDiagnosticObservations.removeValue(forKey: oldest)
            }
            peerEventDiagnosticObservations[peripheral.identifier] = PeerEventDiagnosticObservation(
                event: "\(event) raw=\(event.rawValue)", date: eventDate,
                uptime: eventUptime, centralID: ObjectIdentifier(central)
            )
            connectLog(
                "system connection event received",
                detail: "event=\(event) raw=\(event.rawValue) id=\(peripheral.identifier.uuidString) name=\((peripheral.name ?? "unknown").debugDescription) peripheralState=\(peripheralStateDescription(peripheral.state)) saved=\(savedPeripheralID()?.uuidString ?? "none") savedMatch=\(savedPeripheralID() == peripheral.identifier) oldContext=\(isManualHardReconnectOldContext(central: central, peripheral: peripheral)) recoveryInProgress=\(isAutomaticGATTRecoveryInProgress)",
                direction: .received
            )
            if isManualHardReconnectOldContext(central: central, peripheral: peripheral) {
                switch event {
                case .peerConnected:
                    connectLog(
                        "old central peerConnected while releasing; cancel again",
                        detail: "id=\(peripheral.identifier.uuidString)",
                        direction: .received
                    )
                    central.cancelPeripheralConnection(peripheral)
                case .peerDisconnected:
                    _ = consumeManualHardReconnectOldContextRelease(
                        central: central,
                        peripheral: peripheral,
                        source: "peerDisconnected"
                    )
                @unknown default:
                    break
                }
                return
            }
            // Pairing has its own connection pipeline. System audio events and
            // another glasses' callbacks must not reset or cancel that pipeline.
            guard !isPairingSessionActive,
                  savedPeripheralID() == peripheral.identifier else {
                connectLog("system connection event ignored: target not owned", detail: "id=\(peripheral.identifier.uuidString) pairing=\(isPairingSessionActive)")
                return
            }
            switch event {
            case .peerConnected:
                let wasSystemTransportKnown = systemTransportConnectedPeripheralIDs.contains(
                    peripheral.identifier
                )
                systemTransportConnectedPeripheralIDs.insert(peripheral.identifier)
                print("\(logTag) connectionEvent peerConnected \(peripheral.identifier.uuidString) state=\(peripheral.state.rawValue)")
                connectLog(
                    "connectionEvent peerConnected",
                    detail: "id=\(peripheral.identifier.uuidString) peripheralState=\(peripheralStateDescription(peripheral.state))",
                    direction: .received
                )
                guard autoReconnectEnabled, !userInitiatedDisconnect else { return }
                if !boundBLEStopWaitingForRelease, peripheral.state != .disconnecting,
                   boundBLEReconnectPolicy.resumeOnSystemConnection(
                       targetMatches: savedPeripheralID() == peripheral.identifier) {
                    clearManualHardReconnectRequirement(reason: "new system Bluetooth event after retry limit")
                    failedGATTContext = nil
                    failedGATTRetryGate.reset()
                    standingConnectRecoveryCount = 0
                    connectLog("automatic BLE retry budget resumed by system event", detail: "id=\(peripheral.identifier.uuidString)")
                }
                if stopBoundReconnectIfExhausted() { return }
                guard !isAutomaticGATTRecoveryInProgress else {
                    connectLog(
                        "connectionEvent peerConnected deferred: recovery in progress",
                        detail: "id=\(peripheral.identifier.uuidString)"
                    )
                    return
                }
                if case .ready = connectionState { return }
                if isGATTDiscoveryInProgress { return }
                guard let savedID = savedPeripheralID(), peripheral.identifier == savedID else {
                    print("\(logTag) connectionEvent ignored: not saved peripheral")
                    connectLog("connectionEvent ignored: not saved peripheral", detail: "id=\(peripheral.identifier.uuidString)")
                    return
                }
                if case .failed = connectionState,
                   manualHardReconnectPeripheralID == peripheral.identifier {
                    _ = recoverFailedGATTIfPossible(source: "systemPeerConnected", allowRetry: true)
                    startSystemReconnectMonitor()
                    return
                }
                clearManualHardReconnectRequirement(reason: "fresh system peerConnected")
                // 同一系统连接内的软 GATT 重建也会产生 peerConnected，不能据此清零失败次数。
                // 仅系统层此前确实不在已连接集合时，才视为全新一轮连接。
                if !wasSystemTransportKnown {
                    standingConnectRecoveryCount = 0
                }
                if peripheral.state == .connected {
                    attachToConnectedPeripheral(peripheral)
                } else {
                    // connection event 反映系统传输层已连；CBPeripheral 对本 central
                    // 仍可能是 disconnected。挂起长连请求，等真实 didConnect 后再发现服务。
                    autoReconnectEnabled = true
                    standingConnectAllowed = true
                    reconnectPeripheral = peripheral
                    armSystemAutoConnect(
                        peripheral,
                        force: true,
                        systemTransportObserved: true
                    )
                }
            case .peerDisconnected:
                // cancelPeripheralConnection 是软 GATT 重建的必要步骤，也会产生 peerDisconnected。
                // 此回调属于本轮自动恢复时不能清零次数，否则永远到不了人工重试状态。
                if isAutomaticGATTRecoveryInProgress {
                    connectLog(
                        "connectionEvent peerDisconnected ignored during automatic recovery",
                        detail: "id=\(peripheral.identifier.uuidString)"
                    )
                    return
                }
                systemTransportGracePeripheralIDs.remove(peripheral.identifier)
                systemTransportConnectedPeripheralIDs.remove(peripheral.identifier)
                if savedPeripheralID() == peripheral.identifier { boundBLEStopWaitingForRelease = false }
                if stopBoundReconnectIfExhausted() { return }
                print("\(logTag) connectionEvent peerDisconnected \(peripheral.identifier.uuidString)")
                connectLog(
                    "connectionEvent peerDisconnected",
                    detail: "id=\(peripheral.identifier.uuidString)",
                    direction: .received
                )
                if manualHardReconnectPeripheralID == peripheral.identifier
                    || pendingManualHardReconnectPeripheralID == peripheral.identifier {
                    cancelManualHardReconnectState(reason: "system peerDisconnected")
                    resetConnectionHandles()
                    updateState(.disconnected)
                    startSystemReconnectMonitor()
                }
                if savedPeripheralID() == peripheral.identifier, isConnectionInProgress {
                    cancelAutomaticGATTRecovery(reason: "system peerDisconnected", resetAttempts: true)
                    cancelConnectWatchdog()
                    standingConnectPeripheralID = nil
                    standingConnectAllowed = false
                    centralManager.cancelPeripheralConnection(peripheral)
                    updateState(.disconnected)
                    startSystemReconnectMonitor()
                }
            @unknown default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            guard central === centralManager else { return }
            guard case .scanning = connectionState, !hasStartedConnect else { return }

            logDiscoveredPeripheral(peripheral, advertisementData: advertisementData, rssi: RSSI)

            if let targetID = boundReconnectScanTargetID {
                guard autoReconnectEnabled, !userInitiatedDisconnect,
                      savedPeripheralID() == targetID,
                      peripheral.identifier == targetID else { return }
                boundBLEReconnectPolicy.didRediscoverTarget()
                stopScan()
                reconnectPeripheral = peripheral
                standingConnectAllowed = true
                armSystemAutoConnect(peripheral, force: true)
                return
            }

            if isManualReconnectScan {
                guard manualReconnectMatches(peripheral, advertisementData: advertisementData) else { return }
                print("\(logTag) manual reconnect matched \(peripheral.identifier.uuidString)")
                isManualReconnectScan = false
                isManualReconnectConnect = true
                cancelManualReconnectScanTimeout()
                savePeripheralID(peripheral.identifier)
                connect(to: peripheral, probing: false)
                return
            }

            if isManualPairingScan {
                if nameMatchesPairingModelName(peripheral, advertisementData: advertisementData) {
                    registerNameMatchedPairingDevice(peripheral, advertisementData: advertisementData, rssi: RSSI)
                }
                return
            }

            // 优先：广播里直接带协议服务 UUID
            if advertisesProtocolService(advertisementData) {
                print("\(logTag) MATCHED by advertised service UUID")
                connect(to: peripheral, probing: false)
                return
            }

            // 广播未带服务 UUID 时，加入探测队列（连接后校验服务，不看名字）
            let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) ?? true
            if isConnectable {
                enqueueProbeCandidate(peripheral, rssi: RSSI)
            }
        }
    }

    private func acceptsConnectionCallback(from peripheral: CBPeripheral, event: String) -> Bool {
        let pairingTarget = userPairingTargetID
            ?? (isProbingService ? connectedPeripheral?.identifier : nil)
        let accepted = BLEConnectionTargetPolicy.acceptsCallback(
            from: peripheral.identifier, pairingActive: isPairingSessionActive,
            pairingTarget: pairingTarget,
            boundTarget: homeSelectionTargetID ?? savedPeripheralID()
        )
        if !accepted {
            connectLog("connection callback ignored: stale target", detail: "event=\(event) id=\(peripheral.identifier.uuidString) pairing=\(isPairingSessionActive) pairingTarget=\(pairingTarget?.uuidString ?? "none") saved=\(savedPeripheralID()?.uuidString ?? "none")")
        }
        return accepted
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard central === centralManager else { return }
            if isManualHardReconnectOldContext(central: central, peripheral: peripheral) {
                connectLog(
                    "old central didConnect while releasing; cancel again",
                    detail: "id=\(peripheral.identifier.uuidString)",
                    direction: .received
                )
                central.cancelPeripheralConnection(peripheral)
                return
            }
            guard acceptsConnectionCallback(from: peripheral, event: "didConnect") else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            // A queued connect completion must not revive an unbound device or take
            // ownership back from the dedicated Gen1 OTA central.
            if boundBLEReconnectPolicy.isExhausted {
                central.cancelPeripheralConnection(peripheral)
                _ = stopBoundReconnectIfExhausted()
                return
            }
            let isPairingTarget = isPairingSessionActive && (
                connectedPeripheral === peripheral || userPairingTargetID == peripheral.identifier
            )
            guard !userInitiatedDisconnect, gen1OTAPeripheralID == nil,
                  isPairingTarget || (autoReconnectEnabled && savedPeripheralID() == peripheral.identifier) else {
                connectLog("didConnect ignored: target no longer authorized", detail: "id=\(peripheral.identifier.uuidString)")
                central.cancelPeripheralConnection(peripheral)
                return
            }
            systemTransportConnectedPeripheralIDs.insert(peripheral.identifier)
            systemTransportGracePeripheralIDs.remove(peripheral.identifier)
            if isPairingSessionActive,
               isManualPairingScan,
               !isUserInitiatedPairingConnect,
               !isProbingService {
                connectLog(
                    "stale didConnect ignored during fresh pairing scan",
                    detail: "id=\(peripheral.identifier.uuidString)",
                    direction: .received
                )
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }
            if automaticGATTRecoveryCancellationPeripheralID == peripheral.identifier {
                connectLog(
                    "didConnect received while cancelling old GATT; cancel again",
                    detail: "id=\(peripheral.identifier.uuidString)",
                    direction: .received
                )
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }
            if isAutomaticGATTRecoveryInProgress {
                cancelAutomaticGATTRecovery(reason: "system connected during recovery wait", resetAttempts: false)
            }
            // 探测切换时，上一个外设的连接回调可能延迟到达；只处理当前目标外设，
            // 否则会打断/顶替正在进行的下一轮探测。
            if let current = connectedPeripheral, current.identifier != peripheral.identifier {
                print("\(logTag) didConnect ignored: stale peripheral \(peripheral.identifier.uuidString)")
                connectLog("didConnect ignored: stale peripheral", detail: "id=\(peripheral.identifier.uuidString)")
                return
            }
            if case .ready = connectionState,
               connectedPeripheral?.identifier == peripheral.identifier {
                connectLog(
                    "duplicate didConnect ignored: GATT already ready",
                    detail: "id=\(peripheral.identifier.uuidString)",
                    direction: .received
                )
                return
            }
            cancelDiscoverServicesWorkItem()
            standingConnectPeripheralID = nil
            print("\(logTag) didConnect: \(peripheral.name ?? peripheral.identifier.uuidString), probing=\(isProbingService), peripheralState=\(peripheral.state.rawValue)")
            connectLog(
                "didConnect",
                detail: "name=\(peripheral.name ?? "nil") id=\(peripheral.identifier.uuidString) probing=\(isProbingService) peripheralState=\(peripheralStateDescription(peripheral.state))",
                direction: .received
            )
            connectedPeripheral = peripheral
            peripheral.delegate = self
            beginDiscoverServices(on: peripheral, reason: "didConnect")
            startConnectWatchdog(for: peripheral)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard central === centralManager else { return }
            if savedPeripheralID() == peripheral.identifier, peripheral.state == .disconnected {
                boundBLEStopWaitingForRelease = false
            }
            if consumeManualHardReconnectOldContextRelease(
                central: central,
                peripheral: peripheral,
                source: "didFailToConnect"
            ) {
                return
            }
            guard acceptsConnectionCallback(from: peripheral, event: "didFailToConnect") else { return }
            if consumeAutomaticGATTRecoveryCancellation(for: peripheral, source: "didFailToConnect") {
                return
            }
            if stopBoundReconnectIfExhausted() { return }
            if isPairingSessionActive,
               isManualPairingScan,
               !isUserInitiatedPairingConnect,
               !isProbingService {
                connectLog(
                    "stale didFailToConnect ignored during fresh pairing scan",
                    detail: "id=\(peripheral.identifier.uuidString)",
                    direction: .received
                )
                return
            }
            if centralManager.state != .poweredOn {
                reconnectPeripheral = peripheral
                resetConnectionHandles()
                return
            }
            // 探测切换时，被取消的上一个外设可能延迟回调 didFailToConnect；忽略非当前外设。
            if let current = connectedPeripheral, current.identifier != peripheral.identifier {
                print("\(logTag) didFailToConnect ignored: stale peripheral \(peripheral.identifier.uuidString)")
                return
            }
            cancelConnectWatchdog()
            standingConnectPeripheralID = nil
            print("\(logTag) didFailToConnect: \(error?.localizedDescription ?? "unknown")")
            connectLog(
                "didFailToConnect",
                detail: "error=\(error?.localizedDescription ?? "unknown") id=\(peripheral.identifier.uuidString) autoReconnect=\(autoReconnectEnabled)",
                direction: .received
            )
            if isProbingService {
                handleProbeFailed(reason: error?.localizedDescription ?? "connect failed")
                return
            }
            if failManualHardReconnectIfNeeded(
                for: peripheral,
                reason: error?.localizedDescription ?? "didFailToConnect"
            ) {
                return
            }
            if canAutomaticallyRecoverGATT {
                isBatteryRefreshMode = false
                beginAutomaticGATTRecovery(for: peripheral, reason: "didFailToConnect")
                return
            }
            if isPairingSessionActive {
                if isUserInitiatedPairingConnect {
                    retryUserPairingConnect(reason: error?.localizedDescription ?? "connect failed")
                    return
                }
                resumePairingScanAfterFailure()
                return
            }
            resetConnectionHandles()
            updateState(.failed(error?.localizedDescription ?? L10n.t("BLE连接失败", "BLE connection failed")))
            if autoReconnectEnabled, !userInitiatedDisconnect,
               savedPeripheralID() == peripheral.identifier {
                recordBoundBLEAttemptFailure()
                startSystemReconnectMonitor()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let callbackDate = Date()
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        let callbackPeripheralState = peripheral.state
        let callbackError = error as NSError?
        Task { @MainActor in
            guard central === centralManager else { return }
            if savedPeripheralID() == peripheral.identifier, peripheral.state == .disconnected {
                boundBLEStopWaitingForRelease = false
            }
            recordDisconnectDiagnostics(
                central: central, peripheral: peripheral, error: callbackError,
                callbackDate: callbackDate, callbackUptime: callbackUptime,
                callbackPeripheralState: callbackPeripheralState
            )
            if consumeManualHardReconnectOldContextRelease(
                central: central,
                peripheral: peripheral,
                source: "didDisconnect"
            ) {
                return
            }
            guard acceptsConnectionCallback(from: peripheral, event: "didDisconnect") else { return }
            if let ready = diagnosticReadyObservation, ready.id == peripheral.identifier,
               ready.uptime > callbackUptime, peripheral.state == .connected, isReady {
                connectLog("stale disconnect ignored: newer ready session", detail: "id=\(peripheral.identifier.uuidString) callbackUptime=\(callbackUptime) readyUptime=\(ready.uptime)")
                return
            }
            systemTransportGracePeripheralIDs.remove(peripheral.identifier)
            print("\(logTag) didDisconnect: \(error?.localizedDescription ?? "nil"), userInitiated=\(userInitiatedDisconnect), autoReconnect=\(autoReconnectEnabled)")
            connectLog(
                "didDisconnect",
                detail: "error=\(error?.localizedDescription ?? "nil") userInitiated=\(userInitiatedDisconnect) autoReconnect=\(autoReconnectEnabled) id=\(peripheral.identifier.uuidString)",
                direction: .received
            )
            if consumeAutomaticGATTRecoveryCancellation(for: peripheral, source: "didDisconnect") {
                return
            }
            if stopBoundReconnectIfExhausted() { return }
            if centralManager.state != .poweredOn {
                reconnectPeripheral = peripheral
                resetConnectionHandles()
                updateState(.bluetoothUnavailable(L10n.t("请打开手机蓝牙", "Turn on Bluetooth")))
                return
            }
            // 断开后旧的常驻 connect 已失效，允许重新下发。
            standingConnectPeripheralID = nil

            if let current = connectedPeripheral, current.identifier != peripheral.identifier {
                print("\(logTag) didDisconnect ignored: stale callback \(peripheral.identifier.uuidString)")
                return
            }

            // 顺序探测会 cancelPeripheralConnection 后立刻连接下一个候选，
            // 被取消外设的 didDisconnect 会延迟到达。若它不是当前正在处理的外设，
            // 视为过期回调直接忽略——否则会打断新一轮探测，或在探测结束后误报“设备已断开”。
            if isProbingService, connectedPeripheral?.identifier != peripheral.identifier {
                print("\(logTag) didDisconnect ignored: stale probe callback \(peripheral.identifier.uuidString)")
                return
            }
            if connectedPeripheral == nil, case .scanning = connectionState {
                print("\(logTag) didDisconnect ignored: scanning, no active peripheral")
                return
            }

            cancelConnectWatchdog()
            if let pending = pendingUserPairingPeripheral, peripheral.identifier == pending.identifier {
                print("\(logTag) user pairing: fresh connect after reset")
                resumePendingUserPairingConnect(pending)
                return
            }
            if isProbingService {
                handleProbeFailed(reason: "disconnected during probe")
                return
            }

            if isPairingSessionActive && isUserInitiatedPairingConnect {
                retryUserPairingConnect(reason: error?.localizedDescription ?? "disconnected")
                return
            }

            reconnectPeripheral = peripheral

            if userInitiatedDisconnect {
                resetConnectionHandles()
                clearLiveDeviceIdentity(reason: "didDisconnect-user-initiated")
                userInitiatedDisconnect = false
                autoReconnectEnabled = false
                updateState(.idle)
                return
            }

            if failManualHardReconnectIfNeeded(
                for: peripheral,
                reason: error?.localizedDescription ?? "didDisconnect"
            ) {
                return
            }

            if case .failed = connectionState {
                cancelManualHardReconnectState(reason: "failed session disconnected")
                resetConnectionHandles()
                clearLiveDeviceIdentity(reason: "didDisconnect-after-failure")
                systemTransportConnectedPeripheralIDs.remove(peripheral.identifier)
                standingConnectAllowed = false
                updateState(.disconnected)
                startSystemReconnectMonitor()
                return
            }

            clearLiveDeviceIdentity(reason: "didDisconnect")
            if isConnectionInProgress, !isPairingSessionActive,
               autoReconnectEnabled, savedPeripheralID() == peripheral.identifier {
                recordBoundBLEAttemptFailure()
                if stopBoundReconnectIfExhausted() { return }
            }
            if canAutomaticallyRecoverGATT {
                beginAutomaticGATTRecovery(for: peripheral, reason: "unexpected-disconnect")
                return
            }

            resetConnectionHandles()

            updateState(.disconnected)

            // 对齐 Android BLE 异常断开自动重连：保留绑定身份，约 1.5s 后监控会重挂 connect。
            // 解绑/退登会先走 userInitiatedDisconnect 分支，不会进入此处。
            standingConnectAllowed = true
            connectLog(
                "standing connect remains enabled after disconnect",
                detail: "autoReconnect=\(autoReconnectEnabled) willMonitor=\(autoReconnectEnabled)"
            )
            if autoReconnectEnabled {
                startSystemReconnectMonitor()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension AstraA1BleManager: CBPeripheralDelegate {
    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            self.flushPendingBLEWrites()
        }
    }

    /// Persist discovery evidence in exported logs, including empty/error results.
    /// Cached services are labelled separately and do not prove a fresh discovery.
    private func logProtocolServiceEvidence(_ peripheral: CBPeripheral, error: Error?, source: String) {
        let services = peripheral.services ?? []
        let found = services.map { "\($0.uuid.uuidString)(primary=\($0.isPrimary))" }.joined(separator: ",")
        let expected = Self.supportedServiceUUIDs.map(\.uuidString).joined(separator: ",")
        let matched = services.filter { Self.supportedServiceUUIDs.contains($0.uuid) }.map { $0.uuid.uuidString }.joined(separator: ",")
        let nsError = error as NSError?
        let detail = "diagnosticVersion=1 source=\(source)"
            + "\nperipheral=\(peripheral.identifier.uuidString) name=\((peripheral.name ?? "unknown").debugDescription)"
            + "\nperipheralState=\(peripheralStateDescription(peripheral.state)) appGATTState=\(connectionState) attempt=\(gattDiscoveryAttempt)"
            + "\nexpectedProtocolServiceUUIDs=[\(expected)] gen1ServiceUUID=\(Self.gen1ServiceUUID.uuidString)"
            + "\nreturnedServiceCount=\(services.count) returnedServices=[\(found)] matchedProtocolServices=[\(matched)]"
            + "\nerrorDomain=\(nsError?.domain ?? "none") errorCode=\(nsError.map { String($0.code) } ?? "none") error=\((error?.localizedDescription ?? "none").debugDescription)"
            + "\nprobing=\(isProbingService) pairingActive=\(isPairingSessionActive) userPairing=\(isUserInitiatedPairingConnect)"
            + "\nevidenceScope=iOS_CoreBluetooth_service_result; backend_model_list_does_not_supply_GATT_services"
        connectLog("protocol service discovery evidence", detail: detail, direction: .received)
        DebugLogStore.logBLEEvent("protocol service discovery evidence", detail: detail)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard !shouldIgnoreGATTCallback(from: peripheral, event: "didDiscoverServices") else { return }
            logProtocolServiceEvidence(peripheral, error: error, source: "didDiscoverServices-before-phase-guard")
            guard case .discoveringServices = connectionState,
                  pendingCharacteristicServices.isEmpty else { return }
            cancelDiscoverServicesWorkItem()
            if let error {
                print("\(logTag) didDiscoverServices error: \(error.localizedDescription)")
                if isProbingService {
                    handleProbeFailed(reason: error.localizedDescription)
                } else if gattDiscoveryAttempt < maxGATTDiscoveryAttempts {
                    scheduleDiscoverServices(on: peripheral, delay: 0.5, reason: "retry-after-error")
                } else {
                    failOrRecoverConnectionPipeline(
                        peripheral,
                        reason: "service-discovery-error",
                        message: L10n.t("服务发现失败: \(error.localizedDescription)", "Service discovery failed: \(error.localizedDescription)")
                    )
                }
                return
            }

            let services = peripheral.services ?? []
            print("\(logTag) didDiscoverServices count=\(services.count)")
            for service in services {
                print("\(logTag) found service: \(service.uuid.uuidString)")
            }

            let hasProtocolService = services.contains { Self.supportedServiceUUIDs.contains($0.uuid) }
            if !hasProtocolService {
                connectLog("protocol service missing", detail: "peripheral=\(peripheral.identifier.uuidString) failureStage=service-discovery; see_protocol_service_discovery_evidence; device_identity_query_not_started=true")
                if isProbingService {
                    handleProbeFailed(reason: "no protocol service \(AstraA1BleProtocol.serviceUUID.uuidString)")
                } else if isPairingSessionActive && isUserInitiatedPairingConnect {
                    isUserInitiatedPairingConnect = false
                    updateState(.failed(L10n.t("未找到眼镜协议服务，请确认设备型号", "Glasses protocol service not found. Check device model")))
                } else if isPairingSessionActive {
                    resumePairingScanAfterFailure()
                } else {
                    failOrRecoverConnectionPipeline(
                        peripheral,
                        reason: "protocol-service-missing",
                        message: L10n.t("未找到眼镜协议服务", "Glasses protocol service not found")
                    )
                }
                return
            }

            print("\(logTag) protocol service confirmed")

            if isPairingSessionActive && isProbingService {
                let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let displayName = name.isEmpty ? L10n.t("未知设备", "Unknown device") : name
                addVerifiedPairingDevice(
                    peripheral,
                    displayName: displayName,
                    rssi: activeProbeRSSI ?? minProbeRSSI
                )
                finishPairingListProbe(for: peripheral)
                return
            }

            isProbingService = false

            // 发现协议服务下的特征；若存在标准电池服务(0x180F)一并发现，用它读电量。
            guard let protocolService = services.first(where: { $0.uuid == AstraA1BleProtocol.serviceUUID }) ?? services.first(where: { $0.uuid == Self.gen1ServiceUUID }) else {
                failOrRecoverConnectionPipeline(
                    peripheral,
                    reason: "protocol-service-lost",
                    message: L10n.t("未找到眼镜协议服务", "Glasses protocol service not found")
                )
                return
            }

            var servicesToDiscover = [protocolService]
            if let batteryService = services.first(where: { $0.uuid == AstraA1BleProtocol.batteryServiceUUID }) {
                servicesToDiscover.append(batteryService)
                print("\(logTag) standard battery service 0x180F present, will read 0x2A19")
            }

            pendingCharacteristicDiscoveries = servicesToDiscover.count
            pendingCharacteristicServices = servicesToDiscover
            startConnectWatchdog(for: peripheral)
            for service in servicesToDiscover {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard !shouldIgnoreGATTCallback(from: peripheral, event: "didDiscoverCharacteristics") else { return }
            guard (peripheral.services ?? []).contains(where: { $0 === service }),
                  let pendingIndex = pendingCharacteristicServices.firstIndex(where: { $0 === service }) else {
                connectLog("stale or duplicate characteristic discovery ignored", detail: "service=\(service.uuid.uuidString)")
                return
            }
            pendingCharacteristicServices.remove(at: pendingIndex)
            if let error {
                print("\(logTag) didDiscoverCharacteristics error for \(service.uuid): \(error.localizedDescription)")
                if Self.supportedServiceUUIDs.contains(service.uuid) {
                    pendingCharacteristicDiscoveries = 0
                    if isPairingSessionActive && isUserInitiatedPairingConnect {
                        retryUserPairingConnect(reason: error.localizedDescription)
                    } else {
                        failOrRecoverConnectionPipeline(
                            peripheral,
                            reason: "characteristic-discovery-error",
                            message: L10n.t("通信特征发现失败，请重试", "Communication characteristic discovery failed. Try again.")
                        )
                    }
                    return
                }
            } else {
                print("\(logTag) characteristics for service \(service.uuid.uuidString):")
                for characteristic in service.characteristics ?? [] {
                    print("\(logTag)   - \(characteristic.uuid.uuidString) [\(describeProperties(characteristic.properties))]")
                }
            }

            // Read standard battery percentage only. Gen2 charging comes from chargestat.
            if service.uuid == AstraA1BleProtocol.batteryServiceUUID {
                if let batteryChar = service.characteristics?.first(where: {
                    $0.uuid == AstraA1BleProtocol.batteryLevelCharacteristicUUID
                }) {
                    batteryLevelCharacteristic = batteryChar
                    if batteryChar.properties.contains(.read) {
                        peripheral.readValue(for: batteryChar)
                    }
                    if batteryChar.properties.contains(.notify) {
                        peripheral.setNotifyValue(true, for: batteryChar)
                    }
                    print("\(logTag) subscribed standard battery level 0x2A19")
                }
            }

            pendingCharacteristicDiscoveries = max(0, pendingCharacteristicDiscoveries - 1)
            finishCharacteristicDiscovery(for: peripheral)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if case .failed = connectionState,
               let context = failedGATTContext, context.peripheral === peripheral,
               characteristic === context.notify || characteristic === context.voice {
                if error == nil, characteristic.isNotifying {
                    _ = recoverFailedGATTIfPossible(source: "lateNotificationSubscription", allowRetry: false)
                }
                // A partial Gen1 subscription is evidence, but not READY. The second
                // notification or periodic validation can complete this same session.
                if !isReady { return }
            }
            guard !shouldIgnoreGATTCallback(from: peripheral, event: "didUpdateNotificationState") else { return }
            if let error {
                print("\(logTag) notify enable failed for \(characteristic.uuid): \(error.localizedDescription)")
            } else {
                print("\(logTag) notify enabled for \(characteristic.uuid), isNotifying=\(characteristic.isNotifying)")
            }

            let isProtocolNotify = characteristic === notifyCharacteristic
                || characteristic === gen1VoiceCharacteristic

            if isProtocolNotify {
                // G5K61 is ready only after BOTH control and voice subscriptions.
                if error == nil, characteristic.isNotifying, !protocolNotificationsReady { return }
                isProtocolNotificationEnabled = (error == nil) && protocolNotificationsReady
                isNotificationEnabled = isProtocolNotificationEnabled
                print("[device_status] protocol notify ready=\(isProtocolNotificationEnabled)")
                guard isProtocolNotificationEnabled else {
                    if isPairingSessionActive && isUserInitiatedPairingConnect {
                        retryUserPairingConnect(reason: error?.localizedDescription ?? "notification not enabled")
                    } else {
                        failOrRecoverConnectionPipeline(
                            peripheral,
                            reason: "notification-enable-failed",
                            message: L10n.t("通信通知订阅失败，请重试", "Notification setup failed. Try again.")
                        )
                    }
                    return
                }
                markReadyIfNeeded()
                // getdevstat 仅由进入 .ready 时统一调度，避免 notify 回调再叠一枪。
            }
            // 电池等其它特征的 notify 不触发 ready / getdevstat。
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // 必须在回调内立刻拷贝 value。characteristic.value 会被下一包覆盖；
        // 若拖到 Task/@MainActor 再读，高速 imgrecdata 会丢包/错包（安卓是同步 getValue）。
        let uuid = characteristic.uuid
        let dataCopy = characteristic.value.map { Data($0) }
        let errorCopy = error
        let capturedAt = Date()
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            if uuid == Self.gen1ControlUUID, gen1GuideEventSessionID != nil || errorCopy != nil {
                let nsError = errorCopy.map { $0 as NSError }
                DebugLogStore.logBLEEvent("Gen1 guide GATT callback", detail: "session=\(gen1GuideEventSessionID?.uuidString ?? "nil") source=\(peripheral.identifier) characteristic=\(uuid) currentPeripheral=\(connectedPeripheral === peripheral) currentCharacteristic=\(notifyCharacteristic === characteristic) bytes=\(dataCopy?.count ?? 0) valuePresent=\(dataCopy != nil) error=\(nsError.map { "\($0.domain)/\($0.code): \($0.localizedDescription)" } ?? "none"); payload_logged_after_control_frame_validation", capturedAt: capturedAt)
            }
            if uuid == Self.gen1ControlUUID, errorCopy != nil || dataCopy == nil {
                let nsError = errorCopy.map { $0 as NSError }
                DebugLogStore.logBLEEvent("Gen1 control callback failed", detail: "target=\(peripheral.identifier) errorDomain=\(nsError?.domain ?? "none") errorCode=\(nsError?.code ?? 0) callbackDelaySeconds=\(ProcessInfo.processInfo.systemUptime - receivedUptime) valuePresent=\(dataCopy != nil); cached_payload_not_parsed", capturedAt: capturedAt)
            }
            if uuid == Self.gen1ControlUUID, gen1APImportIdentity != nil {
                let nsError = errorCopy.map { $0 as NSError }
                DebugLogStore.logBLEEvent("Gen1 AP raw callback", detail: "source=\(peripheral.identifier) characteristic=\(uuid) currentPeripheral=\(connectedPeripheral === peripheral) currentCharacteristic=\(notifyCharacteristic === characteristic) bytes=\(dataCopy?.count ?? 0) error=\(nsError.map { "\($0.domain)/\($0.code)" } ?? "none") payload=<credentials-redacted>", capturedAt: capturedAt)
            }
            // 必须在拆帧和旧连接过滤之前记录。无命令头的续包也应留下证据；
            // CoreBluetooth 的 read 与 notify 共用此回调，不能凭等待标志断言来源。
            if uuid == AstraA1BleProtocol.notifyCharacteristicUUID {
                switch rawNotifyDiagnosticBudget.record() {
                case .record:
                    let nsError = errorCopy.map { $0 as NSError }
                    DebugLogStore.logBLERawReceived(
                        data: dataCopy,
                        peripheralID: peripheral.identifier.uuidString,
                        characteristicID: uuid.uuidString,
                        context: "currentPeripheral=\(connectedPeripheral === peripheral) currentCharacteristic=\(notifyCharacteristic === characteristic) readPending=\(notifyReadInFlight) readIssued=\(notifyReadWasIssued) readCommand=\(notifyReadCommand ?? "nil") readRequest=\(notifyReadRequestID); callbackKind=read-or-notify",
                        error: nsError.map { "domain=\($0.domain) code=\($0.code) message=\($0.localizedDescription)" },
                        capturedAt: capturedAt
                    )
                case .limitReached:
                    DebugLogStore.logBLEEvent("RAW capture limit reached", detail: "limit=256; further raw callbacks omitted until connection reset; parsed command logs continue", capturedAt: capturedAt)
                case .suppress:
                    break
                }
            }
            guard !shouldIgnoreGATTCallback(from: peripheral, event: "didUpdateValue") else { return }
            guard characteristic === notifyCharacteristic || characteristic === gen1VoiceCharacteristic
                || characteristic === batteryLevelCharacteristic else { return }
            if deviceGeneration == .gen1G5K61,
               uuid == Self.gen1ControlUUID || uuid == Self.gen1VoiceUUID {
                if gen1FirmwareUpgradeIdentity != nil, uuid == Self.gen1ControlUUID,
                   errorCopy != nil || dataCopy == nil {
                    let nsError = errorCopy.map { $0 as NSError }
                    DebugLogStore.logBLEEvent("Gen1 firmware notify callback failed", detail: "target=\(peripheral.identifier) characteristic=\(uuid) payloadBytes=\(dataCopy?.count ?? 0) errorDomain=\(nsError?.domain ?? "none") errorCode=\(nsError?.code ?? 0); no_payload_dump", capturedAt: capturedAt)
                }
                guard errorCopy == nil, let data = dataCopy else { return }
                if uuid == Self.gen1VoiceUUID { handleGen1VoiceData(data, receivedUptime: receivedUptime) }
                else { handleGen1ControlData(data, capturedAt: capturedAt, receivedUptime: receivedUptime) }
                return
            }
            if let errorCopy {
                let nsError = errorCopy as NSError
                connectLog("characteristic value error", detail: "peripheral=\(peripheral.identifier) characteristic=\(uuid) domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription) readPending=\(notifyReadInFlight) readIssued=\(notifyReadWasIssued)")
                if uuid == AstraA1BleProtocol.notifyCharacteristicUUID {
                    DebugLogStore.logBLEEvent("notify value error", detail: "command=\(notifyReadCommand ?? "nil") domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)", capturedAt: capturedAt)
                    notifyReadInFlight = false
                    notifyReadWasIssued = false
                    if nsError.domain == CBATTErrorDomain,
                       nsError.code == CBATTError.requestNotSupported.rawValue {
                        // 固件不支持读通知特征：本次连接内不再尝试补读。
                        notifyReadUnsupported = true
                        DebugLogStore.logBLEEvent("notify read unsupported", detail: "ATT=0x06; read fallback disabled for current connection")
                    }
                    // 读失败也要收尾，否则等 wificonfig / getworkpat 的调用方只能干等超时。
                    if let command = notifyReadCommand {
                        requestFullNotifyPayload(for: command)
                    } else if isQueryingAboutDeviceInfo {
                        requestFullNotifyPayload(for: "getdevinfo")
                    }
                }
                return
            }
            guard let data = dataCopy else { return }
            print("\(logTag) didUpdateValue char=\(uuid)")

            // 标准电池服务电量（0x2A19）：连接后几乎立刻可读，先展示；
            // 随后 getdevinfo batt0 会覆盖电量。Gen2充电态由 chargestat 独立维护。
            // 读到 0 视为固件尚未采样，忽略。
            if uuid == AstraA1BleProtocol.batteryLevelCharacteristicUUID {
                if let raw = data.first {
                    let percent = max(0, min(100, Int(raw)))
                    if percent == 0 {
                        print("\(logTag) standard battery level 0 ignored")
                    } else if !isBatteryLevelKnown || deviceBattery != "\(percent)" {
                        applyBatteryPercent(percent, source: "bas0x2A19")
                        markDeviceInfoReadyIfNeeded(force: false)
                    }
                }
                return
            }

            if uuid == AstraA1BleProtocol.notifyCharacteristicUUID {
                if notifyReadInFlight {
                    DebugLogStore.logBLEEvent(
                        "notify value while read pending",
                        detail: "request=\(notifyReadRequestID) command=\(notifyReadCommand ?? "nil") readIssued=\(notifyReadWasIssued) bytes=\(data.count); callback may be notification or read response",
                        capturedAt: capturedAt
                    )
                }
                notifyReadInFlight = false
                notifyReadWasIssued = false
            }
            handleNotifyData(data)
        }
    }
}

// MARK: - Wi-Fi 凭据本地缓存

/// 眼镜热点凭据（SSID / 密码 / HTTP 地址）。设备端固定不变，可按 SN 缓存，
/// 后续导入只需发 toopenwifi 拿到状态回包即可，不再依赖会被 MTU 截断的 wificonfig。
struct GlassesWifiCredential: Codable, Equatable {
    var ssid: String
    var password: String
    var httpAddress: String
}

/// 按设备 SN 持久化眼镜热点凭据（支持多副眼镜各自缓存）。
enum GlassesWifiCredentialStore {
    private static let storageKey = "astraA1.wifiCredentials"

    private static func loadAll() -> [String: GlassesWifiCredential] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: GlassesWifiCredential].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func saveAll(_ map: [String: GlassesWifiCredential]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func load(deviceKey: String) -> GlassesWifiCredential? {
        loadAll()[deviceKey]
    }

    static func save(deviceKey: String, credential: GlassesWifiCredential) {
        var map = loadAll()
        map[deviceKey] = credential
        saveAll(map)
    }

    static func remove(deviceKey: String) {
        var map = loadAll()
        map.removeValue(forKey: deviceKey)
        saveAll(map)
    }
}
