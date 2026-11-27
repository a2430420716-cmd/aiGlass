import Combine
import CryptoKit
import Foundation

enum BluetoothOtaUpgradeState: Equatable {
    case idle
    case downloadingFirmware(percent: Int)
    case gettingAlgorithmInfo
    case downloadingAlgorithm
    case openingWifi
    case connectingWifi
    case gettingOtaPath
    case gettingDLLPath
    case uploadingAlgorithm(percent: Int)
    case installingAlgorithm(percent: Int)
    case uploadingFirmware(percent: Int)
    case closingWifi
    case upgrading(percent: Int)
    case completed
    case versionUnconfirmed(String)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .idle, .completed, .versionUnconfirmed, .failed:
            return false
        default:
            return true
        }
    }

    @MainActor
    var statusText: String {
        statusText(kind: nil)
    }

    @MainActor
    func statusText(kind: OtaUpgradeKind?) -> String {
        let upgradingPrefix: String = {
            switch kind {
            case .firmware:
                return L10n.t("正在升级固件", "Updating firmware")
            case .bluetooth, .none:
                return L10n.t("正在升级蓝牙固件", "Updating Bluetooth firmware")
            }
        }()

        switch self {
        case .idle:
            return ""
        case .downloadingFirmware(let percent):
            return L10n.t("正在下载固件 \(percent)%", "Downloading firmware \(percent)%")
        case .gettingAlgorithmInfo:
            return L10n.t("正在查询算法文件信息...", "Checking algorithm files...")
        case .downloadingAlgorithm:
            return L10n.t("正在准备算法文件...", "Preparing algorithm files...")
        case .openingWifi:
            return L10n.t("正在打开眼镜热点...", "Turning on glasses hotspot...")
        case .connectingWifi:
            return L10n.t("正在连接眼镜 Wi-Fi...", "Connecting to glasses Wi-Fi...")
        case .gettingOtaPath:
            return L10n.t("正在获取升级路径...", "Getting update path...")
        case .gettingDLLPath:
            return L10n.t("正在获取算法文件上传路径...", "Getting algorithm upload path...")
        case .uploadingAlgorithm(let percent):
            return L10n.t("正在上传算法文件 \(percent)%", "Uploading algorithm files \(percent)%")
        case .installingAlgorithm(let percent):
            return L10n.t("正在安装算法文件 \(percent)%", "Installing algorithm files \(percent)%")
        case .uploadingFirmware(let percent):
            return L10n.t("正在上传固件 \(percent)%", "Uploading firmware \(percent)%")
        case .closingWifi:
            return L10n.t("正在关闭热点...", "Turning off hotspot...")
        case .upgrading(let percent):
            return "\(upgradingPrefix) \(percent)%"
        case .completed:
            switch kind {
            case .firmware:
                return L10n.t("固件升级完成，设备将自动重启", "Firmware update complete. Device will restart automatically")
            case .bluetooth, .none:
                return L10n.t("蓝牙固件升级完成，设备将自动重启", "Bluetooth firmware update complete. Device will restart automatically")
            }
        case .versionUnconfirmed(let message), .failed(let message):
            return message
        }
    }
}

enum OtaUpgradeKind {
    case bluetooth
    case firmware

    @MainActor
    var pageTitle: String {
        switch self {
        case .bluetooth: L10n.t("眼镜蓝牙升级", "Glasses Bluetooth update")
        case .firmware: L10n.t("眼镜固件升级", "Glasses firmware upgrade")
        }
    }

    @MainActor
    var currentVersionTitle: String {
        switch self {
        case .bluetooth: L10n.t("当前蓝牙版本", "Current Bluetooth version")
        case .firmware: L10n.t("当前固件版本", "Current firmware version")
        }
    }

    @MainActor
    var contentTitlePrefix: String {
        switch self {
        case .bluetooth: L10n.t("蓝牙版本", "Bluetooth version")
        case .firmware: L10n.t("固件版本", "Firmware version")
        }
    }

    @MainActor
    var upgradingStatusPrefix: String {
        switch self {
        case .bluetooth: L10n.t("正在升级蓝牙固件", "Updating Bluetooth firmware")
        case .firmware: L10n.t("正在升级固件", "Updating firmware")
        }
    }
}

extension BluetoothOtaUpgradeState {
    /// 将各阶段进度映射为 0-100 的整体进度，供圆环展示。
    var overallProgress: Int? {
        switch self {
        case .idle, .completed, .versionUnconfirmed, .failed:
            return nil
        case .downloadingFirmware(let percent):
            return min(34, max(1, percent * 34 / 100))
        case .gettingAlgorithmInfo:
            return 36
        case .downloadingAlgorithm:
            return 39
        case .openingWifi:
            return 42
        case .connectingWifi:
            return 48
        case .gettingOtaPath:
            return 62
        case .gettingDLLPath:
            return 51
        case .uploadingAlgorithm(let percent):
            return 52 + min(6, percent * 6 / 100)
        case .installingAlgorithm(let percent):
            return 59 + min(3, percent * 3 / 100)
        case .uploadingFirmware(let percent):
            return 64 + min(16, percent * 16 / 100)
        case .closingWifi:
            return 82
        case .upgrading(let percent):
            return 85 + min(15, percent * 15 / 100)
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .versionUnconfirmed, .failed:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class BluetoothOtaUpgradeManager: ObservableObject {
    @Published private(set) var state: BluetoothOtaUpgradeState = .idle
    @Published private(set) var activeKind: OtaUpgradeKind?
    @Published private(set) var activeTargetVersion: String?
    @Published private(set) var activeTargetID: UUID?
    @Published private(set) var isVerifyingGen1Version = false
    @Published private(set) var isWaitingForBluetooth = false
    @Published private(set) var isCleaningUpPreparation = false
    @Published private(set) var isVerifyingGen2Result = false
    @Published private(set) var isWaitingForDeviceRestart = false
    @Published private(set) var isAwaitingGen1WifiConfirmation = false
    @Published private(set) var manualWifiCredential: Gen2OtaWifiConnectionSession.Credential?
    @Published private(set) var manualWifiError: String?
    @Published private(set) var isCheckingManualWifi = false
    @Published private(set) var hotspotJoinAttempt = 0
    @Published private var gen1FirmwarePhase: Gen1FirmwareUpdateSession.Phase?
    @Published private var gen1BluetoothPhase: Gen1BluetoothOtaSessionState.Phase?

    private let logTag = "[DeviceOTA]"
    private let bluetoothOtaLogTag = "[bluetooth_ota]"
    private var upgradeTask: Task<Void, Never>?
    private var gen1FirmwareSession: Gen1FirmwareUpdateSession?
    private var gen2WifiSession: Gen2OtaWifiConnectionSession?
    private var connectedSSID: String?
    private var isGen1Upgrade = false

    var isUpgrading: Bool { state.isActive }

    var currentStatusText: String {
        if manualWifiCredential != nil {
            return isCheckingManualWifi
                ? L10n.t("正在确认眼镜 Wi-Fi 连接...", "Checking glasses Wi-Fi...")
                : L10n.t("请手动连接眼镜 Wi-Fi 后继续", "Connect to glasses Wi-Fi manually to continue")
        }
        switch state {
        case .openingWifi, .connectingWifi:
            if let guidance = DeviceWifiManager.connectionGuidanceIfNeeded { return guidance }
        default:
            break
        }
        if case .connectingWifi = state, hotspotJoinAttempt > 1 {
            return L10n.t("正在重新连接眼镜 Wi-Fi（2/2）...", "Retrying glasses Wi-Fi (2/2)...")
        }
        if let gen1FirmwarePhase {
            switch gen1FirmwarePhase {
            case .checkingBattery: return L10n.t("正在检查眼镜电量...", "Checking the glasses battery...")
            case .provisioningWifi(let attempt): return L10n.t("正在为眼镜连接 Wi-Fi（\(attempt)/2）...", "Connecting glasses to Wi-Fi (\(attempt)/2)...")
            case .diagnosingWifi: return L10n.t("正在读取眼镜配网结果...", "Reading glasses Wi-Fi diagnostics...")
            case .awaitingWifiConfirmation: return L10n.t("Wi-Fi 配网成功，请确认后开始升级", "Wi-Fi configured. Confirm to start the update")
            case .restarting: return L10n.t("固件已写入，正在重启眼镜...", "Firmware written. Restarting glasses...")
            case .verifyingVersion: return L10n.t("正在等待眼镜重连并核对版本...", "Waiting for glasses to reconnect and verifying the version...")
            case .upgrading, .completed: break
            }
        }
        if isCleaningUpPreparation {
            return L10n.t("正在退出本次升级状态...", "Exiting update mode...")
        }
        if isWaitingForDeviceRestart {
            return L10n.t("固件已写入，正在等待眼镜完成重启，请稍候...", "Firmware written. Waiting for glasses to finish restarting...")
        }
        if isVerifyingGen2Result {
            return L10n.t("正在等待眼镜重连并确认升级结果...", "Waiting for glasses to reconnect and confirm the update...")
        }
        if isWaitingForBluetooth {
            return L10n.t("正在等待眼镜蓝牙恢复...", "Waiting for glasses Bluetooth to reconnect...")
        }
        if isVerifyingGen1Version {
            return L10n.t("正在等待眼镜重连并核对版本...", "Waiting for glasses to reconnect and verifying the version...")
        }
        if state.isActive, let gen1BluetoothPhase {
            switch gen1BluetoothPhase {
            case .transferringLoader(let percent):
                return L10n.t("步骤 1/2：正在向眼镜推送升级文件 \(percent)%", "Step 1/2: Sending update files to glasses \(percent)%")
            case .reconnecting:
                return L10n.t("步骤 1/2 已完成，正在等待眼镜回连...", "Step 1/2 complete. Waiting for glasses to reconnect...")
            case .transferringFirmware(let percent):
                return L10n.t("步骤 2/2：眼镜正在拉取固件 \(percent)%", "Step 2/2: Glasses are downloading firmware \(percent)%")
            case .awaitingResult, .completed:
                return L10n.t("正在等待眼镜确认升级结果...", "Waiting for glasses to confirm the update...")
            }
        }
        return state.statusText(kind: activeKind)
    }

    var overallProgress: Int? {
        guard isGen1Upgrade else { return state.overallProgress }
        if let gen1FirmwarePhase {
            switch gen1FirmwarePhase {
            case .checkingBattery: return 1
            case .provisioningWifi, .diagnosingWifi, .awaitingWifiConfirmation: return 5
            case .upgrading(let percent): return 10 + min(85, max(0, percent) * 85 / 100)
            case .restarting, .verifyingVersion: return 95
            case .completed: return nil
            }
        }
        if isVerifyingGen1Version { return 95 }
        if state.isActive, let gen1BluetoothPhase { return gen1BluetoothPhase.overallProgress }
        switch state {
        case .downloadingFirmware(let percent): return max(0, min(20, percent / 5))
        case .uploadingFirmware(let percent): return 20 + max(0, min(70, percent * 70 / 100))
        case .upgrading(let percent): return max(0, min(95, percent * 95 / 100))
        default: return state.overallProgress
        }
    }

    private func btLog(_ message: String, kind: OtaUpgradeKind) {
        guard kind == .bluetooth else { return }
        print("\(bluetoothOtaLogTag) \(message)")
    }

    func confirmGen1WifiProvision() {
        guard isAwaitingGen1WifiConfirmation,
              gen1FirmwareSession?.confirmWifiProvision() == true else { return }
        isAwaitingGen1WifiConfirmation = false
    }

    func cancelGen1WifiProvision() {
        guard isAwaitingGen1WifiConfirmation,
              gen1FirmwareSession?.cancelWifiProvision() == true else { return }
        isAwaitingGen1WifiConfirmation = false
    }

    func confirmManualWifiConnection() {
        _ = gen2WifiSession?.confirmManualConnection()
    }

    func cancelManualWifiConnection() {
        gen2WifiSession?.cancel()
    }

    func startBluetoothUpgrade(
        serverInfo: DeviceOTAInfo,
        authorization: String?,
        ble: AstraA1BleManager,
        importManager: MediaImportManager
    ) {
        print("\(bluetoothOtaLogTag) start requested version=\(serverInfo.version) url=\(serverInfo.downloadURL)")
        startUpgrade(kind: .bluetooth, serverInfo: serverInfo, authorization: authorization, ble: ble, importManager: importManager)
    }

    /// Explicit recovery of a previously submitted image, using only its saved
    /// BLE loader identity. The transport verifies the SDK's forced-OTA flag.
    func startGen1BluetoothRecovery(record: Gen1BluetoothOtaRecoveryStore.Record,
                                   ble: AstraA1BleManager, importManager: MediaImportManager) {
        guard !isUpgrading, upgradeTask == nil,
              record.permitsLoaderRecovery(
                savedID: ble.savedPeripheralUUIDString.flatMap(UUID.init(uuidString:)),
                accountID: ble.gen1ImportAccount(for: record.targetID)) else { return }
        activeKind = .bluetooth
        activeTargetVersion = record.version
        activeTargetID = record.targetID
        guard !importManager.isImporting, !AIRecordingImportManager.shared.isImporting else {
            state = .failed(L10n.t("文件正在导入，请稍后再恢复升级", "Files are being imported. Try recovery after the import finishes"))
            return
        }
        isGen1Upgrade = true
        isVerifyingGen1Version = false
        gen1FirmwarePhase = nil
        gen1BluetoothPhase = nil
        state = .downloadingFirmware(percent: 0)
        let info = DeviceOTAInfo(version: record.version, downloadURL: record.downloadURL, content: record.content)
        upgradeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.upgradeTask = nil }
            await self.runGen1Upgrade(kind: .bluetooth, serverInfo: info, ble: ble,
                                      gen1Wifi: nil, loaderRecovery: record)
        }
    }

    func startFirmwareUpgrade(
        serverInfo: DeviceOTAInfo,
        authorization: String?,
        ble: AstraA1BleManager,
        importManager: MediaImportManager,
        gen1Wifi: Gen1FirmwareWifiCredentials? = nil
    ) {
        startUpgrade(kind: .firmware, serverInfo: serverInfo, authorization: authorization, ble: ble, importManager: importManager, gen1Wifi: gen1Wifi)
    }

    private func startUpgrade(
        kind: OtaUpgradeKind,
        serverInfo: DeviceOTAInfo,
        authorization: String?,
        ble: AstraA1BleManager,
        importManager: MediaImportManager,
        gen1Wifi: Gen1FirmwareWifiCredentials? = nil
    ) {
        guard !isUpgrading, upgradeTask == nil else { return }
        activeKind = kind
        activeTargetVersion = serverInfo.version
        activeTargetID = nil
        isGen1Upgrade = ble.deviceGeneration == .gen1G5K61
        isVerifyingGen1Version = false
        gen1FirmwarePhase = nil
        gen1BluetoothPhase = nil
        guard ble.isDeviceAvailable, let startingIdentifier = ble.deviceBluetoothIdentifier else {
            state = .failed(L10n.t("请先连接已绑定的眼镜设备", "Please connect your bound glasses first"))
            return
        }
        activeTargetID = UUID(uuidString: startingIdentifier)
        upgradeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.upgradeTask = nil }
            guard ble.isDeviceAvailable, ble.deviceBluetoothIdentifier == startingIdentifier else {
                self.state = .failed(L10n.t("眼镜连接或绑定已改变，升级已停止", "Glasses connection or binding changed. Update stopped"))
                return
            }
            await self.runUpgrade(
                kind: kind,
                serverInfo: serverInfo,
                authorization: authorization,
                ble: ble,
                importManager: importManager,
                gen1Wifi: gen1Wifi
            )
        }
    }

    func resetCompletedState() {
        guard upgradeTask == nil else { return }
        if case .completed = state { state = .idle }
        if case .versionUnconfirmed = state { state = .idle }
        if case .failed = state { state = .idle }
        activeKind = nil
        activeTargetVersion = nil
        activeTargetID = nil
        isVerifyingGen1Version = false
        gen1BluetoothPhase = nil
    }

    private func runUpgrade(
        kind: OtaUpgradeKind,
        serverInfo: DeviceOTAInfo,
        authorization: String?,
        ble: AstraA1BleManager,
        importManager: MediaImportManager,
        gen1Wifi: Gen1FirmwareWifiCredentials? = nil
    ) async {
        btLog(
            "flow begin targetVersion=\(serverInfo.version) bleReady=\(ble.isReady) importing=\(importManager.isImporting) sn=\(ble.deviceSN ?? "nil") bleId=\(ble.deviceBluetoothIdentifier ?? "nil") ver28=\(ble.deviceVersion2800 ?? "nil")",
            kind: kind
        )

        guard ble.isDeviceAvailable else {
            btLog("abort: bound device not available", kind: kind)
            state = .failed(L10n.t("请先连接已绑定的眼镜设备", "Please connect your bound glasses first"))
            return
        }
        guard !importManager.isImporting else {
            btLog("abort: media import in progress", kind: kind)
            state = .failed(L10n.t("相册正在导入，请稍后再升级", "Album is importing. Please try again later"))
            return
        }
        guard !AIRecordingImportManager.shared.isImporting else {
            btLog("abort: recording import in progress", kind: kind)
            state = .failed(L10n.t("录音正在导入，请稍后再升级", "Recording import is in progress. Please try again later"))
            return
        }

        // Gen1 main firmware performs a fresh 0x05 read in its session before
        // provisioning. All other OTA paths enforce the same gate here.
        if !(ble.deviceGeneration == .gen1G5K61 && kind == .firmware),
           let message = ble.firmwareUpgradeBatteryAlertMessage {
            DebugLogStore.logBLEEvent("OTA battery gate blocked", detail: "generation=\(ble.deviceGeneration.rawValue) kind=\(kind) battery=\(ble.deviceBatteryPercent.map(String.init) ?? "unknown") minimum=\(ble.firmwareUpgradeMinimumBatteryPercent)")
            state = .failed(message)
            ble.queryBatteryOnly()
            return
        }

        if ble.deviceGeneration == .gen1G5K61 {
            await runGen1Upgrade(kind: kind, serverInfo: serverInfo, ble: ble, gen1Wifi: gen1Wifi)
            return
        }

        guard ble.deviceGeneration == .gen2,
              let targetID = ble.deviceBluetoothIdentifier.flatMap(UUID.init(uuidString:)) else {
            state = .failed(L10n.t("未能确认当前眼镜，请重新连接后升级", "Could not identify the glasses. Reconnect before updating"))
            return
        }

        let previousVersion = kind == .firmware ? ble.deviceVersion6350 : ble.deviceVersion2800
        ble.beginFirmwareUpgradeFlow()
        var fileName = "firmware.bin"
        var localFileURL: URL?
        var lastUpgradePercent = 0
        var preserveRuntimeStatus = false
        defer {
            isWaitingForBluetooth = false
            isCleaningUpPreparation = false
            isVerifyingGen2Result = false
            isWaitingForDeviceRestart = false
            ble.endFirmwareUpgradeFlow(reason: "ota-flow-finished", preserveRuntimeStatus: preserveRuntimeStatus)
        }

        do {
            let prepared = try await prepareFirmwarePayload(kind: kind, serverInfo: serverInfo) { percent in
                self.state = .downloadingFirmware(percent: percent)
            }
            let firmwareData = prepared.data
            let md5 = prepared.md5
            fileName = prepared.fileName
            btLog(
                "step1 ready source=\(prepared.source) file=\(fileName) bytes=\(firmwareData.count) md5=\(md5)",
                kind: kind
            )

            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ota", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let cachedURL = cacheDir.appendingPathComponent(fileName)
            try firmwareData.write(to: cachedURL, options: .atomic)
            localFileURL = cachedURL
            print("\(logTag) firmware cached \(fileName) bytes=\(firmwareData.count)")
            btLog("step1 cached path=\(cachedURL.path)", kind: kind)

            try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "after-firmware-download")

            let algorithmUpdate: PreparedAlgorithmUpdate
            if kind == .bluetooth {
                state = .gettingAlgorithmInfo
                btLog("DLL_FLOW step=getalgoinf start timeoutMs=10000 + server API start", kind: kind)
                let serverAlgorithmInfoTask = Task { [weak self] in
                    await self?.fetchAlgorithmFileInfo(authorization: authorization)
                }
                do {
                    let deviceAlgorithmInfo = try await ble.queryAlgorithmInfo(timeout: 10)
                    let serverInfo = await serverAlgorithmInfoTask.value
                    btLog(
                        "DLL_FLOW getalgoinf received deviceCount=\(deviceAlgorithmInfo.count) serverAvailable=\(serverInfo != nil)",
                        kind: kind
                    )
                    if let serverInfo {
                        state = .downloadingAlgorithm
                        algorithmUpdate = await prepareAlgorithmUpdate(
                            serverInfo: serverInfo,
                            deviceInfo: deviceAlgorithmInfo,
                            kind: kind
                        )
                    } else {
                        algorithmUpdate = .empty
                    }
                } catch {
                    // 对齐 Android skipDllAndContinueOta：getalgoinf 无回包、发送失败、
                    // 截断或解析失败都只跳过可选 DLL，不阻断蓝牙固件升级。
                    serverAlgorithmInfoTask.cancel()
                    algorithmUpdate = .empty
                    btLog(
                        "DLL_FLOW optional DLL step failed, skip DLL and continue Bluetooth OTA: status=gettingAlgorithmInfo reason=\(error.localizedDescription)",
                        kind: kind
                    )
                }
            } else {
                btLog("skip DLL pre-update for main firmware", kind: kind)
                algorithmUpdate = .empty
            }

            try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "before-opening-hotspot")
            if let message = ble.firmwareUpgradeBatteryAlertMessage {
                throw BluetoothOtaUpgradeError.message(message)
            }
            state = .openingWifi
            btLog("step2 toopenwifi (purpose=ota)", kind: kind)
            DebugLogStore.logWiFi(
                "\(kind == .firmware ? "眼镜固件升级" : "蓝牙固件升级")：开始 Wi-Fi 流程",
                detail: "firmwareFile=\(fileName)\nfirmwareBytes=\(firmwareData.count)\nbleReady=\(ble.isReady)"
            )
            let wifi = try await connectGen2Hotspot(ble: ble, targetID: targetID, kind: kind)
            btLog("step3 hotspot connected", kind: kind)
            DebugLogStore.logWiFi(
                "升级：热点连接成功",
                detail: "kind=\(kind)\nssid=\(wifi.ssid)\nhttp=\(wifi.httpAddress)",
                direction: .received
            )
            try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "after-hotspot-connection")

            if kind == .bluetooth, algorithmUpdate.needsInstall {
                do {
                    state = .gettingDLLPath
                    btLog(
                        "dll step2 getworkpat type=4 files=\(algorithmUpdate.files.count) localJson=\(algorithmUpdate.localJSON != nil)",
                        kind: kind
                    )
                    let receivedDLLPath = try await ble.getDLLWorkPath()
                    let dllBaseURL = Self.resolveDeviceWorkPath(
                        receivedDLLPath,
                        fallbackDirectory: "dll_upload",
                        deviceHTTPBaseURL: wifi.httpAddress
                    )
                    btLog("dll step2 path=\(dllBaseURL)", kind: kind)
                    try await uploadAlgorithmUpdate(
                        algorithmUpdate, baseURL: dllBaseURL, kind: kind,
                        ble: ble, targetID: targetID
                    )

                    try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "before-algorithm-install")
                    state = .installingAlgorithm(percent: 0)
                    btLog("dll step4 dllupload0 count=\(algorithmUpdate.files.count)", kind: kind)
                    let result = try await ble.waitForDLLInstall(
                        items: algorithmUpdate.files.map(\.uploadItem),
                        timeout: 120
                    ) { [weak self] percent in
                        Task { @MainActor in
                            guard let self, !self.isCleaningUpPreparation,
                                  case .installingAlgorithm = self.state else { return }
                            self.state = .installingAlgorithm(percent: percent)
                            self.btLog("dll install progress=\(percent)%", kind: kind)
                        }
                    }
                    guard result.status == 1 else {
                        throw BluetoothOtaUpgradeError.message(
                            L10n.t(
                                "算法文件安装失败，status=\(result.status)，failId=\(result.failID)",
                                "Algorithm install failed, status=\(result.status), failId=\(result.failID)"
                            )
                        )
                    }
                    btLog("dll step5 install success done=\(result.doneCount)", kind: kind)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 对齐 Android skipDllAndContinueOta：DLL 路径、上传、安装命令、
                    // 安装超时或设备明确返回失败，都跳过可选 DLL，继续蓝牙 OTA。
                    let failedDLLStage = String(describing: state)
                    btLog(
                        "DLL_FLOW optional DLL step failed, skip DLL and continue Bluetooth OTA: status=\(failedDLLStage) reason=\(error.localizedDescription)",
                        kind: kind
                    )
                }
            }

            state = .gettingOtaPath
            try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "before-ota-path")
            btLog("step4 getworkpat OTA path", kind: kind)
            let receivedOtaPath = try await ble.getOtaWorkPath()
            try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "before-firmware-upload")
            let otaBaseURL = Self.resolveDeviceWorkPath(
                receivedOtaPath,
                fallbackDirectory: "fw_upload",
                deviceHTTPBaseURL: wifi.httpAddress
            )
            print("\(logTag) ota path=\(otaBaseURL)")
            btLog("step4 ota path=\(otaBaseURL)", kind: kind)

            state = .uploadingFirmware(percent: 0)
            btLog("step5 upload start file=\(fileName) bytes=\(firmwareData.count) md5=\(md5)", kind: kind)
            try await GlassesHTTPClient.uploadFirmware(
                otaBaseURL: otaBaseURL,
                fileName: fileName,
                body: firmwareData
            ) { percent in
                Task { @MainActor in
                    guard !self.isCleaningUpPreparation,
                          case .uploadingFirmware = self.state else { return }
                    self.state = .uploadingFirmware(percent: percent)
                }
            }
            btLog("step5 upload done", kind: kind)

            state = .closingWifi
            btLog("step6 closewifi0 + disconnect hotspot", kind: kind)
            try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "before-hotspot-shutdown")
            try? await ble.closeWifi(timeout: 2)
            disconnectHotspot()
            btLog("step6 hotspot closed", kind: kind)
            DebugLogStore.logWiFi(
                "升级：Wi-Fi 传输结束",
                detail: "kind=\(kind)\nfile=\(fileName)\nbytes=\(firmwareData.count)"
            )

            try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "before-upgrade-command")
            state = .upgrading(percent: 0)
            btLog("step7 \(kind == .firmware ? "otaupload1" : "otaupload0") start file=\(fileName)", kind: kind)
            // 先挂进度回调再发 otaupload，避免首包进度丢失。
            try await ble.waitForOtaUpgradeCompletion { [weak self] percent in
                lastUpgradePercent = percent
                Task { @MainActor in
                    guard let self, !self.isCleaningUpPreparation,
                          case .upgrading = self.state else { return }
                    self.state = .upgrading(percent: percent)
                    if percent == 0 || percent == 100 || percent % 5 == 0 {
                        self.btLog("step7 upgrade progress=\(percent)%", kind: kind)
                    }
                }
            } sendUpgradeCommand: {
                switch kind {
                case .bluetooth:
                    try ble.startBluetoothOtaUpgrade(fileName: fileName)
                case .firmware:
                    try ble.startFirmwareOtaUpgrade(fileName: fileName)
                }
            }

            // Match Android's apply/reboot window. Keep the flow busy throughout.
            isWaitingForDeviceRestart = true
            DebugLogStore.logWiFi("升级：进度完成，等待设备应用升级", detail: "target=\(targetID) kind=\(kind) targetVersion=\(serverInfo.version) wait=60s")
            try await Task.sleep(nanoseconds: 60_000_000_000)
            isWaitingForDeviceRestart = false
            state = .completed
            print("\(logTag) \(kind) upgrade completed file=\(fileName)")
            btLog(
                "step8 completed file=\(fileName) md5=\(md5) targetVersion=\(serverInfo.version) progress=100 applyWait=60s",
                kind: kind
            )
        } catch {
            let failedState = state
            let failedStage = String(describing: state)
            preserveRuntimeStatus = true
            print("\(logTag) upgrade failed: \(error.localizedDescription)")
            btLog("failed: \(error.localizedDescription) lastProgress=\(lastUpgradePercent)%", kind: kind)
            DebugLogStore.logWiFi(
                "升级：Wi-Fi 流程失败",
                detail: "kind=\(kind)\nstage=\(failedStage)\nssid=\(connectedSSID ?? "nil")\nerror=\(error.localizedDescription)",
                direction: .received
            )
            let result: Gen2OtaResultDecision
            if ble.hasSubmittedGen2Ota(for: targetID) {
                result = await reconcileGen2Result(ble, targetID: targetID, kind: kind, targetVersion: serverInfo.version, previousVersion: previousVersion)
            } else {
                result = .failed
            }
            switch result {
            case .completed:
                preserveRuntimeStatus = false
                state = .completed
                DebugLogStore.logWiFi("升级：核验后确认成功", detail: "target=\(targetID) kind=\(kind) targetVersion=\(serverInfo.version) originalError=\(error.localizedDescription); no cancellation sent")
            case .unconfirmed:
                state = .versionUnconfirmed(L10n.t("未收到完整升级结果，暂未确认眼镜的新版本。请稍后重新连接并检查版本，勿重复升级。", "The update result is incomplete and the new version has not been confirmed. Reconnect later and check the version before updating again."))
                DebugLogStore.logWiFi("升级：结果待确认", detail: "target=\(targetID) kind=\(kind) targetVersion=\(serverInfo.version); no cancellation sent")
            case .failed:
                // A retry cannot race cleanup. Submitted upgrades require fresh
                // version + idle evidence; earlier failures own only their preparation.
                if Self.canCleanUpPreparation(in: failedState) {
                    _ = ble.confirmGen2OtaFailure(for: targetID)
                }
                let cleanupStartedAt = ProcessInfo.processInfo.systemUptime
                let cleanupNote = await cleanupGen2Failure(ble, targetID: targetID, failedStage: failedState)
                if ble.hasCompletedGen2Ota(for: targetID) {
                    preserveRuntimeStatus = false
                    state = .completed
                } else if ble.hasGen2OtaProgress(for: targetID, since: cleanupStartedAt) {
                    state = .versionUnconfirmed(L10n.t("眼镜重新上报升级进度，暂不判定失败。请保持供电，稍后重新连接检查版本。", "Glasses resumed reporting update progress. Keep them powered and reconnect later to check the version."))
                } else {
                    state = .failed([error.localizedDescription, cleanupNote].compactMap { $0 }.joined(separator: "\n"))
                }
            }
            disconnectHotspot()
        }

        if let localFileURL {
            try? FileManager.default.removeItem(at: localFileURL)
            btLog("cleanup local cache \(localFileURL.lastPathComponent)", kind: kind)
        }
        btLog("flow end state=\(String(describing: state))", kind: kind)
    }

    /// Consume reports received after our explicit query, never pre-upgrade cached
    /// versions. A slow/missing reboot yields an unconfirmed result, not a failure.
    private func reconcileGen2Result(
        _ ble: AstraA1BleManager, targetID: UUID, kind: OtaUpgradeKind,
        targetVersion: String, previousVersion: String?, timeout: TimeInterval = 90
    ) async -> Gen2OtaResultDecision {
        isVerifyingGen2Result = true
        defer { isVerifyingGen2Result = false }
        let key = kind == .firmware ? "ver63" : "ver28"
        var baselineVersion = ble.gen2OtaVersionReports[key]?.sequence ?? 0
        var baselineStatus = ble.deviceRuntimeStatusReportSequence
        var queryQueued = false
        let startedAt = ProcessInfo.processInfo.systemUptime
        var nextQueryAt = -Double.infinity
        var nextReconnectAt = -Double.infinity
        var lastReportSequence = baselineVersion
        DebugLogStore.logWiFi("升级：开始结果核验", detail: "target=\(targetID) kind=\(kind) key=\(key) previous=\(previousVersion ?? "nil") expected=\(targetVersion) timeout=\(timeout)s baselineVersion=\(baselineVersion) baselineStatus=\(baselineStatus)")
        while !Task.isCancelled {
            guard ble.savedPeripheralUUIDString == targetID.uuidString,
                  ble.deviceBluetoothIdentifier == nil || ble.deviceBluetoothIdentifier == targetID.uuidString else {
                DebugLogStore.logWiFi("升级：停止结果核验", detail: "reason=target-changed expected=\(targetID) saved=\(ble.savedPeripheralUUIDString ?? "nil") current=\(ble.deviceBluetoothIdentifier ?? "nil")")
                return .unconfirmed
            }
            if ble.hasCompletedGen2Ota(for: targetID) { return .completed }
            let now = ProcessInfo.processInfo.systemUptime
            let ready = ble.isReady && ble.deviceGeneration == .gen2 && ble.deviceBluetoothIdentifier == targetID.uuidString
            let report = ble.gen2OtaVersionReports[key]
            let freshVersion = ready && queryQueued && report?.targetID == targetID && (report?.sequence ?? 0) > baselineVersion
                ? report?.version : nil
            let freshIdle = ready && queryQueued && ble.deviceRuntimeStatusReportSequence > baselineStatus
                && ble.lastReportedDeviceRuntimeStatus == .standby
            let decision = Gen2OtaResultDecision.evaluate(targetVersion: targetVersion, previousVersion: previousVersion, freshVersion: freshVersion,
                                                         freshIdle: freshIdle, receivedCompletion: false)
            if let report, report.sequence > lastReportSequence {
                lastReportSequence = report.sequence
                DebugLogStore.logWiFi("升级：版本核验证据", detail: "target=\(report.targetID) key=\(key) actual=\(report.version) expected=\(targetVersion) fresh=\(freshVersion != nil) idle=\(freshIdle) result=\(decision)")
            }
            if decision == .completed { return .completed }
            if now - startedAt >= timeout {
                let resumedProgress = ble.hasGen2OtaProgress(for: targetID, since: startedAt)
                let finalDecision: Gen2OtaResultDecision = resumedProgress ? .unconfirmed : decision
                DebugLogStore.logWiFi("升级：结果核验结束", detail: "target=\(targetID) elapsed=\(now - startedAt)s actual=\(freshVersion ?? "nil") expected=\(targetVersion) freshIdle=\(freshIdle) resumedProgress=\(resumedProgress) result=\(finalDecision)")
                return finalDecision
            }
            if ready, now >= nextQueryAt {
                nextQueryAt = now + 3
                if !queryQueued {
                    baselineVersion = ble.gen2OtaVersionReports[key]?.sequence ?? 0
                    baselineStatus = ble.deviceRuntimeStatusReportSequence
                }
                queryQueued = ble.queryGen2OtaVersion(for: targetID, firmware: kind == .firmware) || queryQueued
                ble.queryGen2OtaRuntimeStatus(for: targetID)
            } else if !ready {
                // Evidence from a connection that subsequently disappeared cannot
                // authorize cancellation after a reboot.
                queryQueued = false
                if now >= nextReconnectAt {
                    nextReconnectAt = now + 2
                    ble.ensureConnected(reason: "ota-result-verification")
                }
            }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return .unconfirmed }
        }
        return .unconfirmed
    }

    /// Hotspot switching can interrupt GATT even after the HTTP service is reachable.
    /// Wait only for the original bound glasses; never carry commands to a replacement.
    private func waitForGen2Bluetooth(
        _ ble: AstraA1BleManager,
        targetID: UUID,
        reason: String,
        timeout: TimeInterval = 30,
        requiresAvailableDevice: Bool = true
    ) async throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var lastReconnectAt = -Double.infinity
        var loggedWait = false
        defer { isWaitingForBluetooth = false }
        while true {
            try Task.checkCancellation()
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let decision = Gen2OtaRecoveryState.connectionDecision(
                targetID: targetID,
                savedID: ble.savedPeripheralUUIDString.flatMap(UUID.init(uuidString:)),
                connectedID: ble.deviceBluetoothIdentifier.flatMap(UUID.init(uuidString:)),
                isReady: ble.isReady,
                isGen2: ble.deviceGeneration == .gen2,
                elapsed: elapsed,
                timeout: timeout
            )
            switch decision {
            case .ready:
                // Recovery still waits on transport readiness. Business preparation also
                // needs the same device to remain represented by an account device card.
                if requiresAvailableDevice, !ble.isDeviceAvailable {
                    guard elapsed < timeout else {
                        throw BluetoothOtaUpgradeError.message(L10n.t("未能确认对应的已绑定眼镜，本次升级已停止", "The bound glasses could not be confirmed. Update stopped"))
                    }
                    isWaitingForBluetooth = true
                    if !loggedWait {
                        loggedWait = true
                        DebugLogStore.logWiFi("升级：等待眼镜身份与设备卡片匹配", detail: "reason=\(reason) peripheral=\(targetID)")
                    }
                    // After GATT recovery an SN-keyed card may need fresh identity replies.
                    // Do not send preparation commands until that identity matches again.
                    try await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                if loggedWait {
                    DebugLogStore.logWiFi("升级：蓝牙已恢复", detail: "reason=\(reason) peripheral=\(targetID) elapsed=\(String(format: "%.1f", elapsed))s")
                }
                return
            case .targetChanged:
                DebugLogStore.logWiFi("升级：目标眼镜已改变", detail: "reason=\(reason) expected=\(targetID) current=\(ble.deviceBluetoothIdentifier ?? "nil") saved=\(ble.savedPeripheralUUIDString ?? "nil")")
                throw BluetoothOtaUpgradeError.message(L10n.t("连接或绑定的眼镜已改变，本次升级已停止", "Connected or bound glasses changed. Update stopped"))
            case .timedOut:
                DebugLogStore.logWiFi("升级：等待蓝牙恢复超时", detail: "reason=\(reason) peripheral=\(targetID) timeout=\(timeout)s")
                throw BluetoothOtaUpgradeError.message(L10n.t("等待眼镜蓝牙恢复超时，请重新连接后升级", "Bluetooth reconnection timed out. Reconnect glasses before updating"))
            case .wait:
                isWaitingForBluetooth = true
                if !loggedWait {
                    loggedWait = true
                    DebugLogStore.logWiFi("升级：等待同一眼镜蓝牙恢复", detail: "reason=\(reason) peripheral=\(targetID) timeout=\(timeout)s")
                }
                if elapsed - lastReconnectAt >= 2 {
                    lastReconnectAt = elapsed
                    ble.ensureConnected(reason: "ota-\(reason)")
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Terminal failures use Android's otacancel0, scoped to this owned attempt.
    /// Submitted upgrades reach this method only after result reconciliation.
    private func cleanupGen2Failure(
        _ ble: AstraA1BleManager,
        targetID: UUID,
        failedStage: BluetoothOtaUpgradeState
    ) async -> String? {
        guard Self.canCleanUpPreparation(in: failedStage),
              ble.canCancelFailedGen2Ota(for: targetID) else {
            DebugLogStore.logWiFi("升级：未发送退出指令", detail: "stage=\(failedStage) reason=no-owned-confirmed-failure-or-already-completed")
            return nil
        }
        isCleaningUpPreparation = true
        defer { isCleaningUpPreparation = false }
        disconnectHotspot()
        do {
            try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "cleanup-preparation", requiresAvailableDevice: false)
            if !ble.hasSubmittedGen2Ota(for: targetID) {
                do {
                    try await ble.closeWifi(timeout: 2)
                } catch {
                    DebugLogStore.logWiFi("升级：关闭热点未确认，仍尝试退出 OTA", detail: error.localizedDescription)
                }
            }
            try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "before-ota-cancel", timeout: 10, requiresAvailableDevice: false)
            let previousStatusSequence = ble.deviceRuntimeStatusReportSequence
            guard ble.cancelFailedGen2Ota(for: targetID) else {
                throw BluetoothOtaUpgradeError.message(L10n.t("退出升级状态指令未发送", "Could not send update cancellation"))
            }
            // A queued command is not an ACK. Require a fresh STANDBY report before
            // telling the user the glasses have left their upgrade preparation state.
            let deadline = ProcessInfo.processInfo.systemUptime + 6
            var nextQueryAt = -Double.infinity
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                guard ble.savedPeripheralUUIDString == targetID.uuidString,
                      ble.deviceBluetoothIdentifier == targetID.uuidString else { break }
                if ble.isReady, ble.deviceRuntimeStatusReportSequence > previousStatusSequence,
                   ble.lastReportedDeviceRuntimeStatus == .standby {
                    DebugLogStore.logWiFi("升级：已确认退出 OTA 状态", detail: "peripheral=\(targetID) freshStatus=STANDBY")
                    return nil
                }
                let now = ProcessInfo.processInfo.systemUptime
                if ble.isReady, now >= nextQueryAt {
                    nextQueryAt = now + 1
                    ble.queryGen2OtaRuntimeStatus(for: targetID)
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            DebugLogStore.logWiFi("升级：退出 OTA 尚未确认", detail: "peripheral=\(targetID) cancelQueued=true status=\(ble.deviceRuntimeStatus.name)")
        } catch {
            DebugLogStore.logWiFi("升级：退出 OTA 未完成", detail: "peripheral=\(targetID) error=\(error.localizedDescription)")
        }
        return L10n.t("尚未确认眼镜退出升级状态，请重新连接并检查设备状态", "Could not confirm exit from update mode. Reconnect and check glasses status")
    }

    // MARK: - Bluetooth OTA algorithm DLL pre-update

    /// Gen1 main firmware pulls its HTTP image; Bluetooth firmware uses vendor RCSP.
    /// Neither path uses Gen2 hotspot, HTTP upload, DLL, or otaupload commands.
    private func runGen1Upgrade(kind: OtaUpgradeKind, serverInfo: DeviceOTAInfo, ble: AstraA1BleManager,
                                gen1Wifi: Gen1FirmwareWifiCredentials?,
                                loaderRecovery: Gen1BluetoothOtaRecoveryStore.Record? = nil) async {
        let canRecoverLoader = loaderRecovery?.permitsLoaderRecovery(
            savedID: ble.savedPeripheralUUIDString.flatMap(UUID.init(uuidString:)),
            accountID: loaderRecovery.flatMap { ble.gen1ImportAccount(for: $0.targetID) }) == true
        guard (ble.isDeviceAvailable && ble.deviceGeneration == .gen1G5K61) || canRecoverLoader,
              let targetIdentifier = loaderRecovery?.targetID.uuidString ?? ble.deviceBluetoothIdentifier,
              let peripheralIdentifier = UUID(uuidString: targetIdentifier),
              ble.savedPeripheralUUIDString == targetIdentifier else {
            state = .failed(L10n.t("无法识别当前绑定的眼镜，请重新连接", "Unable to identify the bound glasses. Reconnect and retry"))
            return
        }
        do { try ble.requireGen1HotspotCleanupFinished(for: peripheralIdentifier) }
        catch { state = .failed(error.localizedDescription); return }
        if kind == .firmware {
            await runGen1MainFirmwareUpgrade(serverInfo: serverInfo, wifi: gen1Wifi, ble: ble)
            return
        }
        guard canRecoverLoader || ble.isDeviceRuntimeIdle else {
            state = .failed(ble.deviceRuntimeStatus.busyMessage)
            return
        }
        ble.beginFirmwareUpgradeFlow(gen1LoaderRecovery: canRecoverLoader ? loaderRecovery : nil)
        defer { ble.endFirmwareUpgradeFlow(reason: "gen1-ota-finished") }
        let ownerAccountID = loaderRecovery?.accountID ?? ble.gen1ImportAccount(for: peripheralIdentifier)
        let sessionID = UUID()
        let log: (String) -> Void = { message in
            DebugLogStore.logBLEEvent("Gen1 Bluetooth OTA", detail: "session=\(sessionID) target=\(targetIdentifier) targetVersion=\(serverInfo.version) \(message)")
        }
        log("started oldVersion=\(ble.deviceVersion2800 ?? "unknown")")

        do {
            if kind == .bluetooth {
                let prepared = try await prepareFirmwarePayload(kind: kind, serverInfo: serverInfo) { percent in
                    self.state = .downloadingFirmware(percent: percent)
                }
                let firmwareSHA256 = SHA256.hash(data: prepared.data).map { String(format: "%02x", $0) }.joined()
                if let expected = loaderRecovery?.firmwareSHA256, expected != firmwareSHA256 {
                    throw BluetoothOtaUpgradeError.message(L10n.t("恢复固件与上次升级文件不一致，请联系技术支持", "The recovery image differs from the previous update. Contact support"))
                }
                try Task.checkCancellation()
                let accountID = ownerAccountID
                let validate: @MainActor () throws -> Void = {
                    guard ble.savedPeripheralUUIDString == targetIdentifier,
                          accountID != nil, ble.gen1ImportAccount(for: peripheralIdentifier) == accountID,
                          ble.deviceBluetoothIdentifier.map({ $0 == targetIdentifier }) ?? true else {
                        throw BluetoothOtaUpgradeError.message(L10n.t("眼镜连接或绑定已改变，升级已停止", "Glasses connection or binding changed. Update stopped"))
                    }
                }
                try validate()
                // The control connection can recover while the image downloads.
                // Use its ordinary readiness, idle and battery gates when available.
                let useLoaderRecovery = canRecoverLoader && !ble.isDeviceAvailable
                guard useLoaderRecovery || (ble.isDeviceAvailable && ble.deviceGeneration == .gen1G5K61
                      && ble.deviceBluetoothIdentifier == targetIdentifier) else {
                    throw BluetoothOtaUpgradeError.message(L10n.t("眼镜连接或绑定已改变，升级已停止", "Glasses connection or binding changed. Update stopped"))
                }
                if !useLoaderRecovery {
                    guard ble.isDeviceRuntimeIdle else {
                        throw BluetoothOtaUpgradeError.message(ble.deviceRuntimeStatus.busyMessage)
                    }
                    if let message = ble.firmwareUpgradeBatteryAlertMessage {
                        throw BluetoothOtaUpgradeError.message(message)
                    }
                }
                log("handoff requested normalBLEReady=\(ble.isReady) \(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
                let disconnectedAt = ProcessInfo.processInfo.systemUptime
                ble.suspendNormalConnectionForGen1OTA()
                do {
                    // Match the vendor handoff delay; iOS cannot disconnect system A2DP/HFP profiles.
                    try await Task.sleep(nanoseconds: 2_500_000_000)
                    guard ble.savedPeripheralUUIDString == targetIdentifier else {
                        throw BluetoothOtaUpgradeError.message(L10n.t("眼镜绑定已改变，升级已停止", "Glasses binding changed. Update stopped"))
                    }
                    log("handoff wait completed elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - disconnectedAt) * 1000)) \(GlassesAudioRouteController.connectionDiagnosticSnapshot.detail)")
                    state = .uploadingFirmware(percent: 0)
                    let transport = Gen1BluetoothOtaTransport()
                    var recoveryRecord = loaderRecovery ?? Gen1BluetoothOtaRecoveryStore.Record(
                        targetID: peripheralIdentifier, version: serverInfo.version,
                        downloadURL: serverInfo.downloadURL, content: serverInfo.content
                    )
                    recoveryRecord.accountID = accountID
                    recoveryRecord.firmwareSHA256 = firmwareSHA256
                    try await transport.upgrade(data: prepared.data, peripheralIdentifier: peripheralIdentifier,
                                                recoveryRecord: recoveryRecord, recoverLoader: useLoaderRecovery,
                                                validateSession: validate, log: log) { phase in
                        self.gen1BluetoothPhase = phase
                        switch phase {
                        case .transferringLoader(let percent): self.state = .uploadingFirmware(percent: percent)
                        case .transferringFirmware(let percent): self.state = .upgrading(percent: percent)
                        case .reconnecting, .awaitingResult, .completed: break
                        }
                    }
                } catch {
                    ble.resumeNormalConnectionAfterGen1OTA()
                    throw error
                }
                log("SDK terminal result accepted; restoring control connection for fresh version verification")
                ble.resumeNormalConnectionAfterGen1OTA()
                state = .upgrading(percent: 100)
                // A 100% transfer or bootloader disconnect alone is not success.
                let actualVersion = try await verifyGen1Version(command: 0x14, targetVersion: serverInfo.version,
                                                               targetIdentifier: targetIdentifier, ble: ble, log: log)
                Gen1BluetoothOtaRecoveryStore().clearAfterVersionConfirmation(
                    targetID: peripheralIdentifier, actualVersion: actualVersion, accountID: ownerAccountID
                )
                state = .completed
                log("completed: fresh device version matched target")
            }
        } catch let error as Gen1OtaVersionVerificationSession.Failure {
            // The SDK finished. A missing post-reboot version is an unknown outcome,
            // not evidence that flashing failed. Do not invite a blind second flash.
            log("version confirmation pending: \(error)")
            state = .versionUnconfirmed(L10n.t(
                "固件传输已完成，暂未确认重启后的版本。请保持眼镜开机，重新连接后检查版本。",
                "Firmware transfer completed, but the version after restart is not yet confirmed. Keep glasses on, reconnect, and check the version."
            ))
        } catch {
            log("stopped error=\(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    private func runGen1MainFirmwareUpgrade(serverInfo: DeviceOTAInfo,
                                            wifi: Gen1FirmwareWifiCredentials?,
                                            ble: AstraA1BleManager) async {
        let diagnosticID = UUID().uuidString
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            guard let wifi else {
                throw BluetoothOtaUpgradeError.message(L10n.t("请输入眼镜连接的 Wi-Fi 名称和密码", "Enter Wi-Fi credentials for the glasses"))
            }
            let payload = try Gen1FirmwareUpdateProtocol.urlPayload(serverInfo.downloadURL, trustedBaseURL: APIClient.baseURL)
            _ = try Gen1FirmwareUpdateProtocol.wifiPayload(ssid: wifi.ssid, password: wifi.password)
            let identity = try ble.beginGen1FirmwareUpgrade()
            defer {
                isAwaitingGen1WifiConfirmation = false
                gen1FirmwareSession = nil
                gen1FirmwarePhase = nil
                ble.endGen1FirmwareUpgrade(identity)
            }
            state = .upgrading(percent: 0)
            DebugLogStore.logWiFi("主固件升级：开始", detail: "diagnosticVersion=2 diagnosticID=\(diagnosticID) target=\(identity.targetID) version=\(serverInfo.version) currentMain=\(ble.deviceVersion6350 ?? "unknown") currentBluetooth=\(ble.deviceVersion2800 ?? "unknown") transport=BLE-provision+device-HTTP-download")
            let session = Gen1FirmwareUpdateSession(
                send: { command, data in
                    guard ble.isGen1FirmwareUpgradeCurrent(identity) else { return false }
                    return ble.sendGen1Command(command: command, payload: data)
                },
                validate: {
                    guard ble.isGen1FirmwareUpgradeCurrent(identity) else {
                        throw Gen1FirmwareUpdateSession.Failure.targetChanged
                    }
                },
                isConnected: { ble.isReady && ble.deviceBluetoothIdentifier == identity.targetID.uuidString },
                reconnect: { ble.ensureConnected(reason: "gen1-ota-version-verification") },
                changed: { phase in
                    self.gen1FirmwarePhase = phase
                    self.isAwaitingGen1WifiConfirmation = phase == .awaitingWifiConfirmation
                    if case .upgrading(let percent) = phase { self.state = .upgrading(percent: percent) }
                },
                log: { message in DebugLogStore.logWiFi("主固件升级", detail: "diagnosticID=\(diagnosticID) target=\(identity.targetID) bleState=\(ble.connectionState) \(message)") }
            )
            gen1FirmwareSession = session
            // Subscribe before querying battery or sending Wi-Fi credentials.
            let subscription = ble.gen1ControlSubject.sink { frame in
                session.receive(command: frame.command, payload: frame.payload)
            }
            defer { subscription.cancel() }
            try await session.run(wifi: wifi, urlPayload: payload, targetVersion: serverInfo.version,
                                  baselineBattery: ble.deviceBatteryPercent)
            state = .completed
            DebugLogStore.logWiFi("主固件升级：版本确认成功", detail: "diagnosticID=\(diagnosticID) target=\(identity.targetID) version=\(serverInfo.version)")
        } catch {
            DebugLogStore.logWiFi("主固件升级：停止", detail: "diagnosticID=\(diagnosticID) elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - startedAt))s bleReady=\(ble.isReady) errorType=\(String(describing: type(of: error))) error=\(error.localizedDescription)")
            if let failure = error as? Gen1FirmwareUpdateSession.Failure {
                switch failure {
                case .wifiConfirmationCancelled:
                    state = .idle
                    DebugLogStore.logWiFi("主固件升级：已取消", detail: "diagnosticID=\(diagnosticID) firmwareStartNotSent=true")
                case .batteryUnknown:
                    state = .failed(L10n.t("未能读取眼镜电量，请重新连接后再升级", "Could not read glasses battery. Reconnect before updating."))
                case .batteryLow(let percent):
                    let minimum = FirmwareUpgradeBatteryPolicy.gen1MinimumPercent
                    state = .failed(L10n.t("眼镜电量不足（当前\(percent)%），请充电至 \(minimum)% 或以上再升级。", "Glasses battery is too low (\(percent)%). Charge to at least \(minimum)% before updating."))
                default:
                    state = .failed(error.localizedDescription)
                }
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func verifyGen1Version(command: UInt8, targetVersion: String, targetIdentifier: String,
                                  ble: AstraA1BleManager, log: @escaping (String) -> Void) async throws -> String {
        isVerifyingGen1Version = true
        defer { isVerifyingGen1Version = false }
        let session = Gen1OtaVersionVerificationSession(send: {
            ble.sendGen1Command(command: command)
        }, validate: {
            guard ble.savedPeripheralUUIDString == targetIdentifier,
                  ble.isGen1OTAVersionRecoveryCurrent(targetIdentifier: targetIdentifier) else {
                throw BluetoothOtaUpgradeError.message(L10n.t("眼镜绑定已改变，版本校验已停止", "Glasses binding changed. Version verification stopped"))
            }
            if ble.isReady, ble.deviceGeneration != .gen1G5K61 || ble.deviceBluetoothIdentifier != targetIdentifier {
                throw BluetoothOtaUpgradeError.message(L10n.t("当前连接的眼镜已改变，版本校验已停止", "Connected glasses changed. Version verification stopped"))
            }
        }, isReady: {
            ble.isReady && ble.deviceBluetoothIdentifier == targetIdentifier
        }, reconnect: {
            log("control reconnect state=\(ble.connectionState)")
            ble.ensureConnected(reason: "gen1-ota-version-verification")
        }, log: log)
        // Subscribe before the first query. Never use the pre-upgrade cached version.
        let subscription = ble.gen1ControlSubject.sink { frame in
            guard frame.command == command, ble.deviceBluetoothIdentifier == targetIdentifier else { return }
            session.receive(payload: frame.payload)
        }
        defer { subscription.cancel() }
        return try await session.run(targetVersion: targetVersion)
    }

    /// Actual cancellation additionally requires ownership and confirmed failure.
    private static func canCleanUpPreparation(in state: BluetoothOtaUpgradeState) -> Bool {
        switch state {
        case .openingWifi, .connectingWifi, .gettingOtaPath, .uploadingFirmware,
             .gettingDLLPath, .uploadingAlgorithm, .installingAlgorithm, .closingWifi, .upgrading:
            return true
        default:
            return false
        }
    }

    private struct AlgorithmFileInfo: Decodable {
        let manifestURL: String?
        let translationURL: String?
        let noiseReductionURL: String?
        let wakeupURL: String?

        enum CodingKeys: String, CodingKey {
            case manifestURL = "algo_manifest_json"
            case translationURL = "pil_algo_ifly_glasses_fanyi_dll"
            case noiseReductionURL = "pil_algo_ifly_glasses_nr_dll"
            case wakeupURL = "pil_algo_ifly_glasses_wakeup_dll"
        }

        func url(for key: String) -> String? {
            switch key {
            case "fanyi": return translationURL
            case "nr": return noiseReductionURL
            case "wakeup": return wakeupURL
            default: return nil
            }
        }
    }

    private struct AlgorithmManifestEnvelope: Decodable {
        let algo: [AlgorithmManifestDTO]?
    }

    private struct AlgorithmManifestDTO: Decodable {
        let id: Int?
        let key: String?
        let name: String?
        let build: UInt64?
        let size: UInt64?
        let md5: String?
    }

    private struct AlgorithmManifestEntry {
        let id: UInt8
        let key: String
        let fileName: String
        let build: UInt32
        let size: Int
        let md5: String
        let downloadURL: String?
    }

    private struct PreparedAlgorithmFile {
        let entry: AlgorithmManifestEntry
        let data: Data
        let md5Data: Data

        var uploadItem: AstraA1BleProtocol.DLLUploadItem {
            AstraA1BleProtocol.DLLUploadItem(
                id: entry.id,
                build: entry.build,
                md5: md5Data,
                fileName: entry.fileName
            )
        }
    }

    private struct PreparedAlgorithmUpdate {
        let files: [PreparedAlgorithmFile]
        let localJSON: Data?

        static let empty = PreparedAlgorithmUpdate(files: [], localJSON: nil)
        var needsInstall: Bool { !files.isEmpty || localJSON != nil }
    }

    /// Android HttpClient GET：接口失败不阻断 OTA，只跳过本轮 DLL 更新。
    private func fetchAlgorithmFileInfo(authorization: String?) async -> AlgorithmFileInfo? {
        do {
            let data = try await APIClient.getRaw(
                path: "algorithm_file/get_algorithm_file",
                authorization: authorization
            )
            let response = try JSONDecoder().decode(APIResponse<AlgorithmFileInfo>.self, from: data)
            print("\(bluetoothOtaLogTag) DLL_FLOW algorithm API success")
            return response.result
        } catch {
            print("\(bluetoothOtaLogTag) DLL_FLOW algorithm API failed, continue OTA: \(error.localizedDescription)")
            return nil
        }
    }

    /// 任一 manifest/DLL 下载或校验失败：对齐 Android，清空待安装文件并继续原 OTA。
    private func prepareAlgorithmUpdate(
        serverInfo: AlgorithmFileInfo,
        deviceInfo: [AstraA1BleProtocol.DeviceAlgorithmInfo],
        kind: OtaUpgradeKind
    ) async -> PreparedAlgorithmUpdate {
        do {
            guard let rawManifestURL = serverInfo.manifestURL,
                  let manifestURL = URL(string: rawManifestURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                btLog("DLL_FLOW manifest URL missing, skip DLL", kind: kind)
                return .empty
            }

            let manifestData = try await Self.downloadAlgorithmData(from: manifestURL)
            let decoded = try JSONDecoder().decode(AlgorithmManifestEnvelope.self, from: manifestData)
            let entries = (decoded.algo ?? []).compactMap { dto -> AlgorithmManifestEntry? in
                guard let rawID = dto.id, (0...Int(UInt8.max)).contains(rawID),
                      let key = dto.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
                      let fileName = dto.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !fileName.isEmpty, fileName == (fileName as NSString).lastPathComponent,
                      let rawBuild = dto.build, rawBuild <= UInt64(UInt32.max),
                      let rawSize = dto.size, rawSize <= UInt64(Int.max),
                      let md5 = dto.md5?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      md5.count == 32 else { return nil }
                let rawURL = serverInfo.url(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return AlgorithmManifestEntry(
                    id: UInt8(rawID),
                    key: key,
                    fileName: fileName,
                    build: UInt32(rawBuild),
                    size: Int(rawSize),
                    md5: md5,
                    downloadURL: rawURL?.isEmpty == false ? rawURL : nil
                )
            }.sorted { $0.id < $1.id }

            guard !entries.isEmpty else {
                btLog("DLL_FLOW manifest empty, skip DLL", kind: kind)
                return .empty
            }

            let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("algorithm_files", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try manifestData.write(
                to: cacheDirectory.appendingPathComponent("algo_manifest.json"),
                options: .atomic
            )

            // Android HashMap.put：异常重复 id 时以最后一条为准，不应触发 Swift Dictionary 重键崩溃。
            var deviceByID: [UInt8: AstraA1BleProtocol.DeviceAlgorithmInfo] = [:]
            for item in deviceInfo {
                deviceByID[item.id] = item
            }
            let needsLocalJSON = deviceInfo.isEmpty || !deviceInfo.contains(where: \.jsonValid)
            let localJSON = needsLocalJSON ? Self.makeLocalAlgorithmJSON(entries: entries) : nil
            if let localJSON {
                try localJSON.write(
                    to: cacheDirectory.appendingPathComponent("algo_local.json"),
                    options: .atomic
                )
            }

            var files: [PreparedAlgorithmFile] = []
            for entry in entries {
                let local = deviceByID[entry.id]
                let needsUpdate = local == nil || local?.fileExists == false || entry.build > (local?.build ?? 0)
                btLog(
                    "DLL_FLOW compare key=\(entry.key) id=\(entry.id) pkgBuild=\(entry.build) devBuild=\(local?.build ?? 0) fileExists=\(local?.fileExists ?? false) jsonValid=\(local?.jsonValid ?? false) needUpdate=\(needsUpdate)",
                    kind: kind
                )
                guard needsUpdate else { continue }
                guard let downloadURL = entry.downloadURL,
                      let url = URL(string: downloadURL) else {
                    btLog("DLL_FLOW algorithm URL missing, skip key=\(entry.key)", kind: kind)
                    continue
                }
                let data = try await Self.downloadAlgorithmData(from: url)
                if entry.size > 0, data.count != entry.size {
                    throw BluetoothOtaUpgradeError.message("algorithm size mismatch: \(entry.fileName)")
                }
                let actualMD5 = Self.md5Hex(data)
                guard actualMD5.caseInsensitiveCompare(entry.md5) == .orderedSame,
                      let md5Data = Self.dataFromMD5Hex(entry.md5) else {
                    throw BluetoothOtaUpgradeError.message("algorithm md5 mismatch: \(entry.fileName)")
                }
                try data.write(
                    to: cacheDirectory.appendingPathComponent(entry.fileName),
                    options: .atomic
                )
                files.append(PreparedAlgorithmFile(entry: entry, data: data, md5Data: md5Data))
                btLog("DLL_FLOW download ready id=\(entry.id) file=\(entry.fileName) bytes=\(data.count)", kind: kind)
            }

            btLog("DLL_FLOW prepared files=\(files.count) localJson=\(localJSON != nil)", kind: kind)
            return PreparedAlgorithmUpdate(files: files, localJSON: localJSON)
        } catch {
            btLog("DLL_FLOW prepare failed, clear DLL and continue OTA: \(error.localizedDescription)", kind: kind)
            return .empty
        }
    }

    private func uploadAlgorithmUpdate(
        _ update: PreparedAlgorithmUpdate,
        baseURL: String,
        kind: OtaUpgradeKind,
        ble: AstraA1BleManager,
        targetID: UUID
    ) async throws {
        let totalFiles = update.files.count + (update.localJSON == nil ? 0 : 1)
        guard totalFiles > 0 else { return }
        var completedFiles = 0

        for file in update.files {
            try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "before-algorithm-file-upload")
            let completedBefore = completedFiles
            let manager = self
            state = .uploadingAlgorithm(percent: completedBefore * 100 / totalFiles)
            btLog("DLL_FLOW upload start id=\(file.entry.id) file=\(file.entry.fileName)", kind: kind)
            try await GlassesHTTPClient.uploadFirmware(
                otaBaseURL: baseURL,
                fileName: file.entry.fileName,
                body: file.data
            ) { filePercent in
                let overall = min(100, (completedBefore * 100 + filePercent) / totalFiles)
                Task { @MainActor in
                    guard !manager.isCleaningUpPreparation,
                          case .uploadingAlgorithm = manager.state else { return }
                    manager.state = .uploadingAlgorithm(percent: overall)
                }
            }
            completedFiles += 1
        }

        if let localJSON = update.localJSON {
            try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "before-algorithm-manifest-upload")
            let completedBefore = completedFiles
            let manager = self
            state = .uploadingAlgorithm(percent: completedBefore * 100 / totalFiles)
            btLog("DLL_FLOW upload algo_local.json", kind: kind)
            try await GlassesHTTPClient.uploadFirmware(
                otaBaseURL: baseURL,
                fileName: "algo_local.json",
                body: localJSON
            ) { filePercent in
                let overall = min(100, (completedBefore * 100 + filePercent) / totalFiles)
                Task { @MainActor in
                    guard !manager.isCleaningUpPreparation,
                          case .uploadingAlgorithm = manager.state else { return }
                    manager.state = .uploadingAlgorithm(percent: overall)
                }
            }
        }
        state = .uploadingAlgorithm(percent: 100)
    }

    private static func downloadAlgorithmData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        AppRequestHeaders.apply(to: &request)
        DebugLogStore.logHTTPSent(
            method: "GET",
            url: url.absoluteString,
            body: "algorithm file download",
            headers: request.allHTTPHeaderFields
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  !data.isEmpty else {
                throw BluetoothOtaUpgradeError.message("algorithm download failed")
            }
            DebugLogStore.logHTTPReceived(
                method: "GET",
                url: url.absoluteString,
                statusCode: http.statusCode,
                body: "<algorithm file \(data.count) bytes>",
                headers: DebugLogStore.headerFields(from: http)
            )
            return data
        } catch {
            DebugLogStore.logHTTPReceived(
                method: "GET",
                url: url.absoluteString,
                statusCode: nil,
                body: nil,
                error: error.localizedDescription
            )
            throw error
        }
    }

    private static func makeLocalAlgorithmJSON(entries: [AlgorithmManifestEntry]) -> Data {
        func value(id: UInt8, key: String) -> AlgorithmManifestEntry? {
            entries.first(where: { $0.id == id }) ?? entries.first(where: { $0.key == key })
        }
        let fanyi = value(id: 0, key: "fanyi")
        let nr = value(id: 1, key: "nr")
        let wakeup = value(id: 2, key: "wakeup")
        let text = "{\n"
            + "  \"fanyi\":{\"build\":\(fanyi?.build ?? 0),\"md5\":\"\(fanyi?.md5 ?? "")\"},\n"
            + "  \"nr\":{\"build\":\(nr?.build ?? 0),\"md5\":\"\(nr?.md5 ?? "")\"},\n"
            + "  \"wakeup\":{\"build\":\(wakeup?.build ?? 0),\"md5\":\"\(wakeup?.md5 ?? "")\"}\n"
            + "}\n"
        return Data(text.utf8)
    }

    private static func dataFromMD5Hex(_ text: String) -> Data? {
        let chars = Array(text.lowercased())
        guard chars.count == 32 else { return nil }
        var result = Data(capacity: 16)
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let value = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            result.append(value)
        }
        return result
    }

    /// Android 用当前眼镜热点网关替换 getworkpat 返回 host，并对空/坏路径回退固定目录。
    private static func resolveDeviceWorkPath(
        _ received: String,
        fallbackDirectory: String,
        deviceHTTPBaseURL: String
    ) -> String {
        func parsedURL(_ raw: String) -> URL? {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard !clean.isEmpty, clean.lowercased() != "http://", clean.lowercased() != "https://" else {
                return nil
            }
            let normalized = clean.hasPrefix("http://") || clean.hasPrefix("https://")
                ? clean
                : "http://" + clean
            guard let url = URL(string: normalized), url.host?.isEmpty == false else { return nil }
            return url
        }

        let gateway = parsedURL(deviceHTTPBaseURL) ?? URL(string: "http://192.168.0.1/")!
        if let original = parsedURL(received),
           var components = URLComponents(url: original, resolvingAgainstBaseURL: false) {
            components.scheme = gateway.scheme ?? "http"
            components.host = gateway.host
            components.port = gateway.port
            if let resolved = components.url?.absoluteString { return resolved }
        }

        var components = URLComponents()
        components.scheme = gateway.scheme ?? "http"
        components.host = gateway.host ?? "192.168.0.1"
        components.port = gateway.port
        components.path = "/\(fallbackDirectory)/"
        return components.url?.absoluteString ?? "http://192.168.0.1/\(fallbackDirectory)/"
    }

    private struct PreparedFirmware {
        let data: Data
        let md5: String
        let fileName: String
        let source: String
    }

    private func prepareFirmwarePayload(
        kind: OtaUpgradeKind,
        serverInfo: DeviceOTAInfo,
        onProgress: @MainActor @escaping (Int) -> Void
    ) async throws -> PreparedFirmware {
        let downloadURL = serverInfo.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !downloadURL.isEmpty, let remoteURL = URL(string: downloadURL) else {
            throw BluetoothOtaUpgradeError.message(L10n.t("固件下载地址无效", "Invalid firmware download URL"))
        }
        let name = Self.firmwareFileName(from: remoteURL)
        onProgress(0)
        print("\(logTag) download start url=\(downloadURL)")
        btLog("step1 download start url=\(downloadURL) file=\(name)", kind: kind)
        let data = try await Task.detached(priority: .userInitiated) {
            try await FirmwareDownloadClient.download(from: remoteURL) { percent in
                Task { @MainActor in
                    onProgress(percent)
                }
            }
        }.value
        guard !data.isEmpty else {
            throw BluetoothOtaUpgradeError.message(L10n.t("固件文件为空", "Firmware file is empty"))
        }
        let md5 = Self.md5Hex(data)
        print("\(logTag) firmware downloaded \(name) bytes=\(data.count)")
        btLog("step1 download done bytes=\(data.count) md5=\(md5)", kind: kind)
        return PreparedFirmware(
            data: data,
            md5: md5,
            fileName: name,
            source: "url:\(downloadURL)"
        )
    }

    private static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private typealias ResolvedWifi = Gen2OtaWifiConnectionSession.Credential

    private func connectGen2Hotspot(ble: AstraA1BleManager, targetID: UUID,
                                    kind: OtaUpgradeKind) async throws -> ResolvedWifi {
        let ownerAccountID = ble.gen1ImportAccount(for: targetID)
        let validate: @MainActor () throws -> Void = {
            guard ble.savedPeripheralUUIDString.flatMap(UUID.init(uuidString:)) == targetID,
                  ownerAccountID != nil, ble.gen1ImportAccount(for: targetID) == ownerAccountID,
                  !ble.hasSubmittedGen2Ota(for: targetID),
                  ble.deviceBluetoothIdentifier.flatMap(UUID.init(uuidString:)).map({ $0 == targetID }) ?? true else {
                throw BluetoothOtaUpgradeError.message(L10n.t("眼镜连接或绑定已改变，升级已停止", "Glasses connection or binding changed. Update stopped"))
            }
        }
        let session = Gen2OtaWifiConnectionSession(
            validate: validate,
            open: { [self] in
                try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "open-ota-hotspot")
                state = .openingWifi
                let wifi = try await resolveWifiCredential(ble: ble)
                connectedSSID = wifi.ssid
                DebugLogStore.logWiFi("升级：热点配置就绪", detail: "kind=\(kind)\nssid=\(wifi.ssid)\nhttp=\(wifi.httpAddress) attempt=\(hotspotJoinAttempt)")
                state = .connectingWifi
                return wifi
            },
            restart: { [self] in
                try validate()
                disconnectHotspot()
                try await waitForGen2Bluetooth(ble, targetID: targetID, reason: "retry-ota-hotspot")
                try await ble.closeWifi(timeout: 3)
                DebugLogStore.logWiFi("升级：重新开启热点后再尝试加入", detail: "peripheral=\(targetID) attempt=2/2 firmwareUploadStarted=false")
            },
            join: { wifi in
                try await DeviceWifiManager.connect(
                    ssid: wifi.ssid, password: wifi.password, probeBaseURL: wifi.httpAddress,
                    diagnosticContext: "ota kind=\(kind) peripheral=\(targetID)",
                    keepConnectionInBackground: true, retainForManualConnection: true,
                    systemApplyTimeout: 45, validateSession: validate
                )
            },
            verify: { wifi in
                try await DeviceWifiManager.verifyManualConnection(
                    ssid: wifi.ssid, probeBaseURL: wifi.httpAddress,
                    diagnosticContext: "ota manual kind=\(kind) peripheral=\(targetID)",
                    validateSession: validate
                )
            },
            canRetry: { error in
                if let error = error as? DeviceWifiError, case .unreachable = error { return true }
                return false
            },
            onPhase: { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .joining(let attempt):
                    self.hotspotJoinAttempt = attempt
                case .awaitingManual(let credential, let error):
                    self.manualWifiCredential = credential
                    self.manualWifiError = error
                    self.isCheckingManualWifi = false
                    DebugLogStore.logWiFi("升级：等待用户手动连接热点", detail: "ssid=\(credential.ssid) timeout=180s firmwareUploadStarted=false")
                case .checkingManual:
                    self.isCheckingManualWifi = true
                case .finished:
                    self.manualWifiCredential = nil
                    self.manualWifiError = nil
                    self.isCheckingManualWifi = false
                    self.hotspotJoinAttempt = 0
                }
            }
        )
        gen2WifiSession = session
        defer { gen2WifiSession = nil }
        do { return try await session.connect() }
        catch Gen2OtaWifiConnectionSession.Failure.manualConnectionTimedOut {
            throw BluetoothOtaUpgradeError.message(L10n.t("手动连接眼镜 Wi-Fi 已超时，请重新升级", "Manual glasses Wi-Fi connection timed out. Start the update again"))
        }
    }

    /// 每次：toopenwifi → 本次 wificonfig（不走缓存）。
    private func resolveWifiCredential(ble: AstraA1BleManager) async throws -> ResolvedWifi {
        let config = try await ble.openWifiAndWaitConfig(purpose: .ota)
        guard let ssid = config.ssid?.trimmingCharacters(in: .whitespacesAndNewlines), !ssid.isEmpty else {
            throw BluetoothOtaUpgradeError.message(L10n.t("未从眼镜获取到 Wi-Fi 名称", "Failed to get Wi-Fi name from glasses"))
        }
        let http = config.httpAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ResolvedWifi(
            ssid: ssid,
            password: config.password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            httpAddress: http.isEmpty ? "http://192.168.0.1/" : http
        )
    }

    private func disconnectHotspot() {
        if let ssid = connectedSSID {
            DeviceWifiManager.disconnect(from: ssid)
            connectedSSID = nil
        }
    }

    private static func firmwareFileName(from url: URL) -> String {
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "firmware.bin" : name
    }
}

private enum BluetoothOtaUpgradeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}
