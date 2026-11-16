import Combine
import Foundation
import UIKit

/// iOS grants finite execution time; this is not an unlimited background download.
@MainActor
private final class MediaImportBackgroundExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private(set) var didExpire = false

    init(onExpiration: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "GlassesMediaImport") { [weak self] in
            Task { @MainActor in
                guard let self, self.identifier != .invalid else { return }
                self.didExpire = true
                onExpiration()
                self.end()
            }
        }
        DebugLogStore.logWiFi("相册导入：申请有限后台执行时间", detail: "granted=\(identifier != .invalid)")
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                let event = notification.name.rawValue
                Task { @MainActor in
                    DebugLogStore.logWiFi("相册导入：App 生命周期", detail: "event=\(event) backgroundTimeRemaining=\(UIApplication.shared.backgroundTimeRemaining)")
                }
            })
        }
    }

    func end() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard identifier != .invalid else { return }
        let finished = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(finished)
    }
}

/// Covers short system UI interruptions without cancelling local processing on
/// expiration. iOS may still tear down Wi-Fi; this is a finite execution grant.
@MainActor
private final class Gen1ImportInterruptionProtection {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var backgroundAt: TimeInterval?
    private var expiredDuringInterruption = false
    private var ended = false

    init() {
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let name = notification.name
                Task { @MainActor [weak self] in self?.receive(name) }
            })
        }
        if UIApplication.shared.applicationState != .active { begin() }
    }

    private func begin() {
        guard !ended, !expiredDuringInterruption, identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Gen1ImportInterruption") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.ended else { return }
                self.expiredDuringInterruption = true
                DebugLogStore.logWiFi("短暂失活保护额度到期", detail: "cancelImport=false cancelStabilize=false systemMaySuspend=true")
                self.releaseGrant()
            }
        }
        DebugLogStore.logWiFi("申请短暂失活保护", detail: "backgroundTaskActive=\(identifier != .invalid) finiteExecution=true")
    }

    private func receive(_ name: Notification.Name) {
        guard !ended else { return }
        if name == UIApplication.didBecomeActiveNotification {
            let duration = backgroundAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            DebugLogStore.logWiFi("返回前台结束失活保护", detail: "backgroundDurationSeconds=\(duration) backgroundTaskActive=\(identifier != .invalid)")
            backgroundAt = nil
            expiredDuringInterruption = false
            releaseGrant()
        } else {
            if name == UIApplication.didEnterBackgroundNotification { backgroundAt = ProcessInfo.processInfo.systemUptime }
            begin()
            DebugLogStore.logWiFi("导入短暂失活", detail: "event=\(name.rawValue) backgroundTaskActive=\(identifier != .invalid) cancelImport=false cancelStabilize=false")
        }
    }

    private func releaseGrant() {
        guard identifier != .invalid else { return }
        let grant = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(grant)
    }

    func end() {
        ended = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        releaseGrant()
    }
}

struct MediaImportFailureRecord: Equatable, Identifiable {
    let id = UUID()
    let fileName: String
    let mediaType: String
    let fileIndex: Int
    let totalFiles: Int
    let stage: String
    let baseURL: String
    let bytesDownloaded: Int?
    let errorDetail: String
}

struct MediaImportFailureReport: Equatable {
    let startedAt: Date
    let deviceSN: String?
    let deviceReady: Bool
    let expectedFileCount: Int
    let wifiSSID: String
    let httpBaseURL: String
    let totalListedFiles: Int
    let importedCount: Int
    let purgedCount: Int
    let failedPhotoCount: Int
    let failedVideoCount: Int
    let importedFileNames: [String]
    let listedFileNames: [String]
    let failureRecords: [MediaImportFailureRecord]
    var credentialSource: String = "wificonfig"
    var transportName: String = "HTTP"

    var formattedLog: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = [
            "=== AIGlass 相册导入失败日志 ===",
            "时间: \(formatter.string(from: startedAt))",
            "设备 SN: \(deviceSN ?? "未知")",
            "设备已连接: \(deviceReady ? "是" : "否")",
            "预期待导入数量: \(expectedFileCount)",
            "Wi-Fi SSID: \(wifiSSID)",
            "Wi-Fi 凭据来源: \(credentialSource)",
            "\(transportName) Base URL: \(httpBaseURL)",
            "列表文件总数: \(totalListedFiles)",
            "成功导入: \(importedCount)",
            "跳过(空文件/损坏): \(purgedCount)",
            "失败照片: \(failedPhotoCount)",
            "失败视频: \(failedVideoCount)",
            "",
            "--- 列表文件 ---",
        ]

        if listedFileNames.isEmpty {
            lines.append("(空)")
        } else {
            for (index, name) in listedFileNames.enumerated() {
                lines.append("\(index + 1). \(name)")
            }
        }

        lines.append("")
        lines.append("--- 成功导入文件 ---")
        if importedFileNames.isEmpty {
            lines.append("(无)")
        } else {
            for (index, name) in importedFileNames.enumerated() {
                lines.append("\(index + 1). \(name)")
            }
        }

        lines.append("")
        lines.append("--- 失败明细 ---")
        if failureRecords.isEmpty {
            lines.append("(无)")
        } else {
            for (index, record) in failureRecords.enumerated() {
                lines.append("[\(index + 1)] \(record.mediaType) | \(record.fileName) | \(record.fileIndex)/\(record.totalFiles)")
                lines.append("阶段: \(record.stage)")
                lines.append("\(transportName) Base URL: \(record.baseURL)")
                if let bytesDownloaded = record.bytesDownloaded {
                    lines.append("已下载字节数: \(bytesDownloaded)")
                }
                lines.append("错误详情:")
                lines.append(record.errorDetail)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }
}

enum MediaImportState: Equatable {
    case idle
    case openingWifi
    case connectingWifi
    case fetchingList
    case downloading(current: Int, total: Int, fileName: String)
    case finishing
    case completed(imported: Int, failedPhotos: Int = 0, failedVideos: Int = 0)
    case failed(String)
}

/// Credentials stay in memory only while this import owns the device hotspot.
struct ManualGlassesWifiJoin: Identifiable, Equatable {
    let id = UUID()
    let ssid: String
    let password: String
}

private enum ManualWifiJoinExit: Error { case restartHotspot }

@MainActor
final class MediaImportManager: ObservableObject {
    static let shared = MediaImportManager()

    @Published private(set) var state: MediaImportState = .idle
    @Published private(set) var lastFailureReport: MediaImportFailureReport?
    @Published private(set) var completionNotice: String?
    @Published private(set) var pendingGen1RecoveryCount = 0
    @Published private var isClosingGen1Hotspot = false

    @Published private(set) var manualWifiJoin: ManualGlassesWifiJoin?
    @Published private(set) var manualWifiHotspotMayBeOff = false
    private var manualWifiRetryID: UUID?
    private var manualWifiRestartID: UUID?
    private var restartGen1ImportAfterCleanup = false

    func retryManualWifiJoin(id: UUID) {
        guard manualWifiJoin?.id == id, !manualWifiHotspotMayBeOff else { return }
        manualWifiRetryID = id
    }

    func cancelManualWifiJoin(id: UUID) {
        guard manualWifiJoin?.id == id else { return }
        DebugLogStore.logWiFi("用户取消手动连接", detail: "cancelReason=userCancelledManualJoin")
        importTask?.cancel()
    }

    func restartManualWifiHotspot(id: UUID) {
        guard manualWifiJoin?.id == id else { return }
        manualWifiRestartID = id
    }

    private func waitForManualWifiJoin(_ credentials: Gen1HotspotCredentials,
                                       ble: AstraA1BleManager,
                                       hotspot: Gen1HotspotSession,
                                       requireLANRejoin: Bool = false,
                                       diagnostics: ImportDiagnosticContext) async throws {
        let request = ManualGlassesWifiJoin(ssid: credentials.ssid, password: credentials.password)
        manualWifiRetryID = nil
        manualWifiRestartID = nil
        manualWifiHotspotMayBeOff = hotspot.availability.requiresRestart
        manualWifiJoin = request
        diagnostics.log("等待用户手动连接热点", detail: "ssid=\(credentials.ssid) timeout=300s appSentCloseHotspot=false deviceAPAvailability=\(hotspot.availability.rawValue) requiresRestart=\(hotspot.availability.requiresRestart) historyIncludesSystemJoin=true retryKind=TCPOnly noApply=true noOpenHotspot=true")
        defer {
            manualWifiJoin = nil
            manualWifiRetryID = nil
            manualWifiRestartID = nil
            manualWifiHotspotMayBeOff = false
        }
        // Replay this open's history as well as new reports. A fast 4 -> 0
        // during system join must not be lost before the manual card appears.
        let statusObservation = hotspot.$availability.sink { [weak self] availability in
            guard availability.requiresRestart, let self else { return }
            self.manualWifiHotspotMayBeOff = true
            self.manualWifiRetryID = nil
            diagnostics.log("手动连接提示使用本轮关机记录", detail: "appSentCloseHotspot=false availability=\(availability.rawValue) action=offerExplicitRestart TCPRetryAllowed=false")
        }
        defer { statusObservation.cancel() }
        // After a TCP failure, an unchanged LAN address must not trigger an
        // endless retry loop. Resume automatically only after leaving and rejoining.
        var observedOutsideLAN = !DeviceWifiManager.gen1HasClientIPv4
        let deadline = ProcessInfo.processInfo.systemUptime + 300
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard ble.isGen1MediaImportCurrent(hotspot.identity) else { throw Gen1APImportError.targetChanged }
            if manualWifiRestartID == request.id {
                diagnostics.log("用户请求重新开启热点，先清理旧会话", detail: "restartReason=networkNotFound cleanupRequired=true")
                throw ManualWifiJoinExit.restartHotspot
            }
            if manualWifiRetryID == request.id, !hotspot.availability.requiresRestart {
                diagnostics.log("用户确认已连接，直接重试 TCP", detail: "retryKind=TCPOnly endpoint=192.168.4.1:8556")
                return
            }
            let hasClientIPv4 = DeviceWifiManager.gen1HasClientIPv4
            if !hasClientIPv4 { observedOutsideLAN = true }
            if hasClientIPv4 && !hotspot.availability.requiresRestart && (!requireLANRejoin || observedOutsideLAN) {
                diagnostics.log("手动连接等待期间检测到眼镜网段，自动继续导入", detail: "targetLAN=192.168.4.0/24 retryKind=TCPOnly endpoint=192.168.4.1:8556 noApply=true noOpenHotspot=true requireLANRejoin=\(requireLANRejoin)")
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        diagnostics.log("手动连接等待超时，进入热点清理", detail: "timeout=300s")
        throw DeviceWifiError.unreachable
    }

    private let logTag = "[MediaImport]"
    private var connectedSSID: String?
    private var importTask: Task<Void, Never>?

    var isImporting: Bool {
        switch state {
        case .idle, .completed, .failed:
            return false
        default:
            return true
        }
    }

    /// 导入进度 0...1，用于导入条上的进度条。
    var progress: Double {
        switch state {
        case .idle:
            return 0
        case .openingWifi:
            return 0.05
        case .connectingWifi:
            return 0.1
        case .fetchingList:
            return 0.15
        case .downloading(let current, let total, _):
            guard total > 0 else { return 0.15 }
            return 0.15 + 0.8 * (Double(current) / Double(total))
        case .finishing:
            return 0.98
        case .completed:
            return 1.0
        case .failed:
            return 0
        }
    }

    var statusText: String {
        if manualWifiJoin != nil {
            return L10n.t("等待手动连接眼镜 Wi-Fi", "Waiting for manual glasses Wi-Fi connection")
        }
        switch state {
        case .idle:
            return ""
        case .openingWifi:
            return L10n.t("正在开启眼镜热点...", "Turning on glasses hotspot...")
        case .connectingWifi:
            return L10n.t("正在连接眼镜 Wi-Fi...", "Connecting to glasses Wi-Fi...")
        case .fetchingList:
            return L10n.t("正在获取文件列表...", "Getting file list")
        case .downloading(let current, let total, _):
            return L10n.t("正在导入 \(current)/\(total)", "Importing \(current)/\(total)")
        case .finishing:
            if isClosingGen1Hotspot {
                return L10n.t("正在等待眼镜热点关闭，请勿重复导入...", "Waiting for glasses hotspot shutdown. Please wait before importing again...")
            }
            return L10n.t("正在完成导入...", "Finishing import...")
        case .completed(let imported, let failedPhotos, let failedVideos):
            if failedPhotos > 0 || failedVideos > 0 {
                return L10n.t("已导入 \(imported) 项，部分失败", "Imported \(imported) item(s), some failed")
            }
            if imported == 0 {
                return L10n.t("眼镜中暂无可导入的照片或视频", "No photos or videos to import")
            }
            return L10n.t("已导入 \(imported) 项", "Imported \(imported) item(s)")
        case .failed(let message):
            return message
        }
    }

    /// 任务不随页面销毁；切后台仅在系统允许的有限时间内继续，到期取消并清理。
    func beginImport(
        ble: AstraA1BleManager,
        library: MediaLibrary,
        expectedFileCount: Int = 0,
        autoSaveToPhotoLibrary: Bool = false,
        recoverLocalFilesOnly: Bool = false
    ) {
        guard !isImporting, importTask == nil else { return }
        refreshGen1Recovery(ble: ble)
        // Completed phone originals need neither BLE nor a charged/idle device.
        // Recovery is an independent action. A permanently undecodable original
        // must not prevent the user from importing new files from the glasses.
        if recoverLocalFilesOnly, pendingGen1RecoveryCount > 0,
           let targetID = ble.savedPeripheralUUIDString.flatMap(UUID.init(uuidString:)),
           let accountID = ble.gen1ImportAccount(for: targetID) {
            importTask = Task { [weak self] in
                await self?.recoverGen1LocalFiles(ble: ble, library: library, targetID: targetID, accountID: accountID, autoSave: autoSaveToPhotoLibrary)
                self?.importTask = nil
            }
            return
        }
        guard ble.isDeviceAvailable else {
            state = .failed(L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first"))
            return
        }
        lastFailureReport = nil
        completionNotice = nil
        importTask = Task { [weak self] in
            repeat {
                self?.restartGen1ImportAfterCleanup = false
                await self?.startImport(
                    ble: ble,
                    library: library,
                    expectedFileCount: expectedFileCount,
                    autoSaveToPhotoLibrary: autoSaveToPhotoLibrary
                )
            } while self?.restartGen1ImportAfterCleanup == true && !Task.isCancelled
            self?.importTask = nil
        }
    }

    private func startImport(
        ble: AstraA1BleManager,
        library: MediaLibrary,
        expectedFileCount: Int = 0,
        autoSaveToPhotoLibrary: Bool
    ) async {
        guard !isImporting else { return }
        guard !AIRecordingImportManager.shared.isImporting else {
            state = .failed(L10n.t("录音正在导入，请稍后再试", "Recording import in progress, try again later"))
            return
        }
        guard ble.isDeviceAvailable else {
            state = .failed(L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first"))
            return
        }
        if ble.deviceGeneration == .gen1G5K61 {
            await startGen1Import(ble: ble, library: library, expectedFileCount: expectedFileCount, autoSave: autoSaveToPhotoLibrary)
            return
        }
        guard !ble.isBatteryTooLowForMedia else {
            state = .failed(ble.lowBatteryMediaMessage)
            return
        }

        // 保持亮屏覆盖热点连接、下载、媒体处理和保存；不随相册页面切换而提前释放。
        let previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            // 成功、失败或任务取消退出时，都恢复导入前的自动锁屏状态。
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }

        let startedAt = Date()
        let diagnostics = ImportDiagnosticContext(kind: "album", ble: ble)
        diagnostics.log(
            "相册导入：开始 Wi-Fi 流程",
            detail: "expectedFileCount=\(expectedFileCount)\nautoSaveToPhotoLibrary=\(autoSaveToPhotoLibrary)\nbleReady=\(ble.isReady)"
        )
        let backgroundExecution = MediaImportBackgroundExecution { [weak self] in
            diagnostics.log("相册导入：后台执行时间到期", detail: "action=cancel-transfer-and-remove-hotspot; unfinished_files_remain_on_device")
            self?.importTask?.cancel()
            self?.disconnectHotspot()
        }
        defer { backgroundExecution.end() }

        do {
            // 进热点前鉴权（需公网）。CheckLicense 参数与 demo 一致传空串。
            PixSmartEIS.prewarmLicense()

            state = .openingWifi
            print("\(logTag) Step1: toopenwifi → wificonfig")
            let wifi = try await resolveWifiCredential(ble: ble)
            connectedSSID = wifi.ssid
            print("\(logTag) wifi ssid=\(wifi.ssid) http=\(wifi.httpAddress)")
            diagnostics.log(
                "相册导入：热点配置就绪",
                detail: "ssid=\(wifi.ssid)\npasswordEmpty=\(wifi.password.isEmpty)\nhttp=\(wifi.httpAddress)",
                direction: .received
            )

            try await requireAvailableDevice(ble)
            state = .connectingWifi
            print("\(logTag) Step2: join hotspot")
            try await DeviceWifiManager.connect(
                ssid: wifi.ssid,
                password: wifi.password,
                probeBaseURL: wifi.httpAddress,
                diagnosticContext: diagnostics.connectionContext,
                diagnosticID: diagnostics.id,
                deviceEvidence: { diagnostics.deviceEvidence },
                keepConnectionInBackground: true
            )
            diagnostics.log(
                "相册导入：热点连接成功",
                detail: "ssid=\(wifi.ssid)\nhttp=\(wifi.httpAddress)",
                direction: .received
            )

            try await requireAvailableDevice(ble)
            state = .fetchingList
            // HTTP 地址以本次 wificonfig 为准；为空再兜底。
            var baseURL = wifi.httpAddress
            if baseURL.isEmpty {
                print("\(logTag) Step3: getworkpat (BLE)")
                baseURL = (try? await ble.getDownloadWorkPath()) ?? ""
            }
            if baseURL.isEmpty { baseURL = "http://192.168.0.1/" }
            if !baseURL.hasSuffix("/") { baseURL += "/" }
            print("\(logTag) work path=\(baseURL)")

            print("\(logTag) Step4: GET file list (HTTP)")
            diagnostics.log("相册导入：开始读取目录", detail: "url=\(baseURL)", direction: .sent)
            let fileNames = try await fetchMediaFileList(ble: ble, baseURL: baseURL, expectedCount: expectedFileCount)
            diagnostics.log("相册导入：目录读取完成", detail: "url=\(baseURL) fileCount=\(fileNames.count)", direction: .received)
            if fileNames.isEmpty { ble.noteEmptyMediaDirectory() }
            print("\(logTag) parsed files=\(fileNames)")

            var importedNames: [String] = []
            var filesToDeleteOnDevice: [String] = []
            var purgedFromDeviceCount = 0
            var failedPhotoCount = 0
            var failedVideoCount = 0
            var failureRecords: [MediaImportFailureRecord] = []
            for (index, name) in fileNames.enumerated() {
                try await requireAvailableDevice(ble)
                state = .downloading(current: index + 1, total: fileNames.count, fileName: name)

                let data: Data
                do {
                    data = try await downloadFile(ble: ble, baseURL: baseURL, fileName: name)
                } catch GlassesHTTPError.emptyBody {
                    purgedFromDeviceCount += 1
                    filesToDeleteOnDevice.append(name)
                    print("\(logTag) \(name) 为 0 字节空文件，稍后删除并跳过")
                    continue
                } catch {
                    if Self.isWifiConnectivityFailure(error) {
                        print("\(logTag) Wi-Fi unavailable during download, abort batch")
                        throw error
                    }
                    if Self.shouldDeleteUnopenableFile(error) {
                        purgedFromDeviceCount += 1
                        filesToDeleteOnDevice.append(name)
                        print("\(logTag) \(name) 文件无法打开，稍后删除并跳过：\(error.localizedDescription)")
                        continue
                    }

                    Self.recordFailure(
                        fileName: name,
                        fileIndex: index + 1,
                        totalFiles: fileNames.count,
                        stage: "download",
                        baseURL: baseURL,
                        bytesDownloaded: nil,
                        error: error,
                        failureRecords: &failureRecords,
                        failedPhotoCount: &failedPhotoCount,
                        failedVideoCount: &failedVideoCount
                    )
                    continue
                }

                try Task.checkCancellation()
                do {
                    let item = try await library.importOriginal(data: data, fileName: name)
                    importedNames.append(name)
                    filesToDeleteOnDevice.append(name)
                    print("\(logTag) imported \(name) bytes=\(data.count)，稍后统一删设备文件")
                    if autoSaveToPhotoLibrary {
                        do {
                            try await SystemPhotoLibrarySaver.save(
                                fileURL: library.originalURL(for: item),
                                isVideo: item.isVideo
                            )
                            print("\(logTag) auto-saved to system Photos: \(name)")
                        } catch {
                            // 对齐 Android：系统相册保存失败不影响 App 内导入，也不保留设备文件重试。
                            print("\(logTag) auto-save Photos failed \(name): \(error.localizedDescription)")
                        }
                    }
                } catch {
                    if Self.shouldDeleteUnopenableFile(error) {
                        purgedFromDeviceCount += 1
                        filesToDeleteOnDevice.append(name)
                        print("\(logTag) \(name) 文件无法打开，稍后删除并跳过：\(error.localizedDescription)")
                        continue
                    }

                    Self.recordFailure(
                        fileName: name,
                        fileIndex: index + 1,
                        totalFiles: fileNames.count,
                        stage: "importToLibrary",
                        baseURL: baseURL,
                        bytesDownloaded: data.count,
                        error: error,
                        failureRecords: &failureRecords,
                        failedPhotoCount: &failedPhotoCount,
                        failedVideoCount: &failedVideoCount
                    )
                }
            }

            try Task.checkCancellation()
            state = .finishing
            // 对齐安卓 FileImportManager：transferok → deletefile → closewifi。
            // 连热点会打断 BLE；下载期间可能还在重连。等 ready 再收尾。
            let uniqueDeletes = Array(Set(filesToDeleteOnDevice))
            let transferOK = failedPhotoCount == 0 && failedVideoCount == 0
            print("\(logTag) Step5a: wait BLE ready then transferok=\(transferOK) delete=\(uniqueDeletes.count)")
            if await waitUntilBLEReady(ble, timeout: 30) {
                ble.sendTransferOK(success: transferOK)
                // 对齐安卓：transferok 后稍等再删（批次间 250ms）。
                try? await Task.sleep(nanoseconds: 250_000_000)
                let deleted = await deleteDeviceFilesWithRetry(ble: ble, fileNames: uniqueDeletes)
                ble.noteImportedMediaFiles(count: deleted)
            } else {
                print("\(logTag) BLE not ready after download, skip transferok/delete (pending banner may linger)")
            }

            print("\(logTag) Step5b: closewifi (imported=\(importedNames.count) purged=\(purgedFromDeviceCount) failedPhotos=\(failedPhotoCount) failedVideos=\(failedVideoCount))")
            try? await ble.closeWifi()
            disconnectHotspot()
            // Android FileImportManager：完成后本地状态立即回 STANDBY，再补查设备状态。
            ble.syncDeviceStatusAfterImport(reason: "media-import-complete")

            // 退热点后再等 BLE，再查 pending，避免用到断开瞬间的脏计数。
            if await waitUntilBLEReady(ble, timeout: 20) {
                ble.queryPendingImportFiles()
            } else {
                print("\(logTag) BLE not ready after closewifi; retaining count after confirmed deletion")
            }

            if failedPhotoCount > 0 || failedVideoCount > 0 {
                lastFailureReport = MediaImportFailureReport(
                    startedAt: startedAt,
                    deviceSN: ble.deviceSN,
                    deviceReady: ble.isReady,
                    expectedFileCount: expectedFileCount,
                    wifiSSID: wifi.ssid,
                    httpBaseURL: baseURL,
                    totalListedFiles: fileNames.count,
                    importedCount: importedNames.count,
                    purgedCount: purgedFromDeviceCount,
                    failedPhotoCount: failedPhotoCount,
                    failedVideoCount: failedVideoCount,
                    importedFileNames: importedNames,
                    listedFileNames: fileNames,
                    failureRecords: failureRecords
                )
            }
            try Task.checkCancellation()
            state = .completed(
                imported: importedNames.count,
                failedPhotos: failedPhotoCount,
                failedVideos: failedVideoCount
            )
            print("\(logTag) done imported=\(importedNames.count)")
            diagnostics.log(
                "相册导入：Wi-Fi 流程结束",
                detail: "imported=\(importedNames.count)\nfailedPhotos=\(failedPhotoCount)\nfailedVideos=\(failedVideoCount)"
            )
        } catch {
            let failedStage = String(describing: state)
            let message = backgroundExecution.didExpire
                ? L10n.t("后台导入已中断，请保持 App 在前台后重新导入，未完成的文件仍保留在眼镜中。", "Background import was interrupted. Keep the app open and import again. Unfinished files remain on the glasses.")
                : error.localizedDescription
            state = .failed(message)
            print("\(logTag) FAILED: \(error.localizedDescription)")
            let nsError = error as NSError
            diagnostics.log(
                "相册导入：Wi-Fi 流程失败",
                detail: "stage=\(failedStage)\nssid=\(connectedSSID ?? "nil")\nerrorDomain=\(nsError.domain) errorCode=\(nsError.code)\nerror=\(error.localizedDescription)\ncallerTaskCancelled=\(Task.isCancelled) phase=before-device-cleanup",
                direction: .received
            )
            try? await ble.closeWifi()
            disconnectHotspot()
            // Android 的 error/cancel 路径同样 resetDeviceImportState(STANDBY)。
            ble.syncDeviceStatusAfterImport(reason: "media-import-failed")
            diagnostics.log("相册导入：失败清理结束", detail: "deviceCleanupAttempted=true; close_result_is_recorded_in_BLE_and_WiFi_logs")
        }
    }

    // MARK: - First-generation AP + TCP import (does not enter the Gen2 HTTP flow)

    func refreshGen1Recovery(ble: AstraA1BleManager) {
        guard let target = ble.savedPeripheralUUIDString.flatMap(UUID.init(uuidString:)),
              let account = ble.gen1ImportAccount(for: target) else {
            pendingGen1RecoveryCount = 0
            return
        }
        pendingGen1RecoveryCount = (try? Gen1ImportInbox().completedEntries(for: target, accountID: account).count) ?? 0
    }

    private func commitGen1File(
        _ entry: Gen1ImportInbox.Entry,
        inbox: Gen1ImportInbox,
        library: MediaLibrary,
        autoSave: Bool,
        validateOwnership: () throws -> Void
    ) async throws -> StoredMediaItem {
        try validateOwnership()
        let processingStarted = ProcessInfo.processInfo.systemUptime
        var processingCompleted = false
        DebugLogStore.logWiFi("开始处理已下载原件", detail: "file=\(entry.fileName) appState=\(UIApplication.shared.applicationState.rawValue) glassesLANIPv4=\(DeviceWifiManager.gen1HasClientIPv4) processingOrder=perFile")
        defer {
            DebugLogStore.logWiFi("已下载原件处理退出", detail: "file=\(entry.fileName) completed=\(processingCompleted) elapsedSeconds=\(ProcessInfo.processInfo.systemUptime - processingStarted) appState=\(UIApplication.shared.applicationState.rawValue) glassesLANIPv4=\(DeviceWifiManager.gen1HasClientIPv4) taskCancelled=\(Task.isCancelled)")
        }
        let watermark = PhotoCaptureWatermarkStore.shared.configuration(fileName: entry.fileName,
            account: entry.accountID, device: entry.targetID.uuidString)
        let item = try await library.importGen1Original(fileURL: inbox.fileURL(for: entry), fileName: entry.fileName, watermark: watermark)
        try validateOwnership()
        if autoSave {
            do {
                try await SystemPhotoLibrarySaver.save(fileURL: library.originalURL(for: item), isVideo: item.isVideo)
            } catch {
                DebugLogStore.logWiFi("保存系统相册失败，App 原件已保留", detail: "file=\(entry.fileName) error=\(error.localizedDescription)")
                throw MediaImportError.message(L10n.t(
                    "\(entry.fileName) 的 App 原件已保存，但系统相册保存失败；可再次导入重试：\(error.localizedDescription)",
                    "The app original for \(entry.fileName) is safe, but saving to Photos failed. Import again to retry: \(error.localizedDescription)"
                ))
            }
        }
        try validateOwnership()
        // Permanent original and app manifest have committed. A cleanup failure can be
        // retried safely because the library receipt deduplicates this exact source URL.
        do { try inbox.removeCommitted(entry) }
        catch { DebugLogStore.logWiFi("待恢复目录清理失败", detail: "file=\(entry.fileName) error=\(error.localizedDescription)") }
        processingCompleted = true
        return item
    }

    private func recoverGen1LocalFiles(
        ble: AstraA1BleManager, library: MediaLibrary, targetID: UUID, accountID: String, autoSave: Bool
    ) async {
        let authorizationID = ble.gen1ImportAuthorizationID
        let ownershipWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                if ble.gen1ImportAuthorizationID != authorizationID || ble.gen1ImportAccount(for: targetID) != accountID {
                    self?.importTask?.cancel()
                    return
                }
            }
        }
        defer { ownershipWatch.cancel() }
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle; refreshGen1Recovery(ble: ble) }
        state = .fetchingList
        lastFailureReport = nil
        completionNotice = nil
        let startedAt = Date()
        var importedNames: [String] = []
        var listedNames: [String] = []
        var failures: [MediaImportFailureRecord] = []
        var failedPhotos = 0
        var failedVideos = 0
        func checkOwnership() throws {
            try Task.checkCancellation()
            guard ble.gen1ImportAuthorizationID == authorizationID,
                  ble.gen1ImportAccount(for: targetID) == accountID else {
                throw Gen1APImportError.targetChanged
            }
        }
        defer {
            if !failures.isEmpty {
                lastFailureReport = MediaImportFailureReport(
                    startedAt: startedAt, deviceSN: ble.deviceSN, deviceReady: ble.isReady,
                    expectedFileCount: listedNames.count, wifiSSID: "",
                    httpBaseURL: "local://Gen1ImportInbox", totalListedFiles: listedNames.count,
                    importedCount: importedNames.count, purgedCount: 0,
                    failedPhotoCount: failedPhotos, failedVideoCount: failedVideos,
                    importedFileNames: importedNames, listedFileNames: listedNames, failureRecords: failures,
                    credentialSource: "local recovery", transportName: "Local"
                )
            }
        }
        do {
            let inbox = Gen1ImportInbox()
            let entries = try inbox.completedEntries(for: targetID, accountID: accountID)
            listedNames = entries.map(\.fileName)
            for (index, entry) in entries.enumerated() {
                try checkOwnership()
                state = .downloading(current: index + 1, total: entries.count, fileName: entry.fileName)
                do {
                    _ = try await commitGen1File(entry, inbox: inbox, library: library, autoSave: autoSave, validateOwnership: checkOwnership)
                    importedNames.append(entry.fileName)
                } catch {
                    try checkOwnership()
                    if error is CancellationError { throw error }
                    let isVideo = Self.isGen1VideoFileName(entry.fileName)
                    if isVideo { failedVideos += 1 } else { failedPhotos += 1 }
                    failures.append(MediaImportFailureRecord(
                        fileName: entry.fileName, mediaType: isVideo ? "video" : "photo",
                        fileIndex: index + 1, totalFiles: entries.count, stage: "localRecovery",
                        baseURL: "local://Gen1ImportInbox", bytesDownloaded: nil,
                        errorDetail: Self.formatErrorDetail(error)
                    ))
                    DebugLogStore.logWiFi("本地恢复失败，原件保留并继续下一项", detail: "file=\(entry.fileName) error=\(error.localizedDescription)")
                }
            }
            try checkOwnership()
            state = .completed(imported: importedNames.count, failedPhotos: failedPhotos, failedVideos: failedVideos)
        } catch {
            state = .failed(L10n.t("已恢复 \(importedNames.count) 项，剩余原件仍保留在手机：\(error.localizedDescription)", "Recovered \(importedNames.count) item(s). Remaining originals are retained on this phone: \(error.localizedDescription)"))
        }
    }

    private static func isGen1VideoFileName(_ name: String) -> Bool {
        isVideoFileName(name) || name.lowercased().hasSuffix(".avi")
    }

    private func startGen1Import(
        ble: AstraA1BleManager, library: MediaLibrary, expectedFileCount: Int, autoSave: Bool
    ) async {
        guard let targetID = ble.deviceBluetoothIdentifier.flatMap(UUID.init(uuidString:)) else {
            state = .failed(Gen1APImportError.unavailable.localizedDescription)
            return
        }
        guard !ble.isBatteryTooLowForMedia else { state = .failed(ble.lowBatteryMediaMessage); return }
        let identity: Gen1APImportIdentity
        do { identity = try ble.beginGen1MediaImport(targetID: targetID) }
        catch { state = .failed(error.localizedDescription); return }

        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let startedAt = Date()
        let deviceSN = ble.deviceSN
        let diagnostics = ImportDiagnosticContext(kind: "gen1-album", ble: ble)
        let hotspot = Gen1HotspotSession(ble: ble, identity: identity)
        let interruptionProtection = Gen1ImportInterruptionProtection()
        defer { interruptionProtection.end() }
        let inbox = Gen1ImportInbox()
        var client: Gen1MediaTCPClient?
        var ssid: String?
        var endpoint = "unavailable"
        var remainingFileCount: Int?
        var listedNames: [String] = []
        var importedNames: [String] = []
        var failures: [MediaImportFailureRecord] = []
        var failedPhotos = 0
        var failedVideos = 0
        var finalError: Error?
        var transferFinishWarning = false
        let identityWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                if !ble.isGen1MediaImportCurrent(identity) {
                    self?.importTask?.cancel()
                    return
                }
            }
        }
        defer {
            identityWatch.cancel()
            ble.endGen1MediaImport(identity, remainingFileCount: remainingFileCount)
            isClosingGen1Hotspot = false
            UIApplication.shared.isIdleTimerDisabled = previousIdle
            refreshGen1Recovery(ble: ble)
        }
        func checkTarget() throws {
            guard ble.isGen1MediaImportCurrent(identity) else { throw Gen1APImportError.targetChanged }
            try Task.checkCancellation()
        }
        func record(_ name: String, index: Int, total: Int, stage: String, error: Error) {
            if Self.isGen1VideoFileName(name) { failedVideos += 1 } else { failedPhotos += 1 }
            failures.append(MediaImportFailureRecord(
                fileName: name, mediaType: Self.isGen1VideoFileName(name) ? "video" : "photo",
                fileIndex: index, totalFiles: total, stage: stage, baseURL: endpoint,
                bytesDownloaded: nil, errorDetail: Self.formatErrorDetail(error)
            ))
            diagnostics.log("文件导入失败，保留手机现有原始数据", detail: "file=\(name) stage=\(stage) error=\(error.localizedDescription)")
        }

        state = .fetchingList
        diagnostics.log("开始 AP 相册导入", detail: "target=\(targetID) transport=TCP:8556")
        do {
            // License activation may need internet. Finish this while still on the
            // phone's normal network, before switching to the glasses' local AP.
            if PixSmartVideoEIS.gen1StabilizationEnabled {
                let licensed = await Task.detached(priority: .utility) {
                    PixSmartImageStabilizer.prewarmLicense()
                }.value
                diagnostics.log("视频防抖预鉴权结束", detail: "licensed=\(licensed); failure_keeps_original_video")
            } else {
                diagnostics.log("临时测试版跳过视频防抖预鉴权", detail: "testVariant=gen1-no-eis stabilizationEnabled=false")
            }
            try checkTarget()
            // Restore previously completed downloads first; do not ask glasses to send
            // those deleted originals again after a processing failure or app restart.
            let recovered = try inbox.completedEntries(for: targetID, accountID: identity.accountID)
            for (index, entry) in recovered.enumerated() {
                try checkTarget()
                state = .downloading(current: index + 1, total: recovered.count, fileName: entry.fileName)
                do {
                    _ = try await commitGen1File(entry, inbox: inbox, library: library, autoSave: autoSave, validateOwnership: checkTarget)
                    importedNames.append(entry.fileName)
                } catch { record(entry.fileName, index: index + 1, total: recovered.count, stage: "localRecovery", error: error) }
            }
            try checkTarget()
            state = .openingWifi
            let credentials = try await hotspot.open()
            ssid = credentials.ssid
            try checkTarget()
            state = .connectingWifi
            do {
                _ = try await DeviceWifiManager.connectGen1(
                    ssid: credentials.ssid, password: credentials.password,
                    diagnosticID: diagnostics.id, deviceEvidence: { diagnostics.deviceEvidence },
                    validateSession: {
                        try checkTarget()
                        guard !hotspot.availability.requiresRestart else { throw DeviceWifiError.hotspotStopped }
                    }
                )
            } catch {
                try checkTarget()
                if case DeviceWifiError.userDenied = error { throw error }
                diagnostics.log("自动加入未完成，转手动连接或重新开启热点", detail: "error=\(error.localizedDescription) availability=\(hotspot.availability.rawValue) requiresRestart=\(hotspot.availability.requiresRestart)")
                try await waitForManualWifiJoin(credentials, ble: ble, hotspot: hotspot, diagnostics: diagnostics)
            }
            endpoint = "tcp://192.168.4.1:8556"
            // One bounded recovery budget across connection, list and file transfer.
            // Keep AP ownership and phone configuration until recovery is exhausted.
            var pathRetryCount = 0
            func withPathRecovery<T>(
                _ initial: Gen1MediaTCPClient,
                operation: (Gen1MediaTCPClient) async throws -> T
            ) async throws -> T {
                var current = initial
                while true {
                    try checkTarget()
                    while !DeviceWifiManager.gen1HasClientIPv4 || hotspot.availability.requiresRestart {
                        try await waitForManualWifiJoin(credentials, ble: ble, hotspot: hotspot, diagnostics: diagnostics)
                        try checkTarget()
                    }
                    do {
                        try await current.connect()
                        let result = try await operation(current)
                        client = current
                        return result
                    } catch {
                        try checkTarget()
                        guard await current.canRetryAfterPathChange(error) else { throw error }
                        let denied = await current.hadLocalNetworkDenial()
                        await current.close()
                        guard pathRetryCount < 3 else {
                            diagnostics.log("网络抖动重试耗尽", detail: "retryCount=3 localNetworkDenied=\(denied) error=\(Self.formatErrorDetail(error))")
                            if denied && DeviceWifiManager.gen1HasClientIPv4 {
                                throw DeviceWifiError.joinFailed("本地网络连接持续受限，请检查「设置 → App → 本地网络」权限；若使用 VPN，请暂时关闭后重试")
                            }
                            throw error
                        }
                        while !DeviceWifiManager.gen1HasClientIPv4 || hotspot.availability.requiresRestart {
                            diagnostics.log("传输网络不可用，等待手动连接或重开热点", detail: "availability=\(hotspot.availability.rawValue) noApply=true noOpenHotspot=true")
                            try await waitForManualWifiJoin(credentials, ble: ble, hotspot: hotspot, diagnostics: diagnostics)
                        }
                        let delays: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000]
                        let delay = delays[pathRetryCount]
                        pathRetryCount += 1
                        let interfaces = WifiDiagnosticSession.captureInterfaces()
                        let tunnelInterfaces = Set(interfaces.addresses.filter { $0.name.hasPrefix("utun") }.map(\.name)).sorted().joined(separator: ",")
                        diagnostics.log("仍在眼镜网段，重试 TCP", detail: "retryIndex=\(pathRetryCount) maxRetries=3 selectedIPv4=\(interfaces.selectedIPv4 ?? "none") tunnelInterfaces=\(tunnelInterfaces) tunnelDoesNotProveVPN=true delayNs=\(delay) keptHotspot=true localNetworkDenied=\(denied) noApply=true noOpenHotspot=true error=\(Self.formatErrorDetail(error))")
                        try await Task.sleep(nanoseconds: delay)
                        try checkTarget()
                        while !DeviceWifiManager.gen1HasClientIPv4 || hotspot.availability.requiresRestart {
                            try await waitForManualWifiJoin(credentials, ble: ble, hotspot: hotspot, diagnostics: diagnostics)
                        }
                        current = Gen1MediaTCPClient(host: "192.168.4.1")
                        client = current
                    }
                }
            }
            var connectedTransport: Gen1MediaTCPClient?
            while connectedTransport == nil {
                try checkTarget()
                guard DeviceWifiManager.gen1HasClientIPv4, !hotspot.availability.requiresRestart else {
                    diagnostics.log("热点连接条件不满足，提示手动连接或重开热点", detail: "targetLAN=192.168.4.0/24 availability=\(hotspot.availability.rawValue) TCPAttempted=false")
                    try await waitForManualWifiJoin(credentials, ble: ble, hotspot: hotspot, diagnostics: diagnostics)
                    continue
                }
                let transport = Gen1MediaTCPClient(host: "192.168.4.1")
                client = transport
                do {
                    // Keep observing after apply returns: its callback can precede the
                    // actual Wi-Fi switch and DHCP completion. This never gates TCP on SSID.
                    do {
                        let networkDiagnostics = WifiDiagnosticSession(
                            targetSSID: credentials.ssid, context: "gen1-tcp-connect", id: diagnostics.id,
                            deviceEvidence: { diagnostics.deviceEvidence }, joinOnce: false
                        )
                        networkDiagnostics.recordSnapshot(phase: "tcp-connect-start", force: true)
                        let sampling = Task { @MainActor in
                            while !Task.isCancelled {
                                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                                guard !Task.isCancelled else { return }
                                networkDiagnostics.recordSnapshot(phase: "tcp-connect-waiting", force: true)
                            }
                        }
                        defer { sampling.cancel(); networkDiagnostics.stop() }
                        do {
                            try await withPathRecovery(transport, operation: { _ in
                                try Task.checkCancellation()
                            })
                            networkDiagnostics.recordSnapshot(phase: "tcp-connect-ready", force: true)
                        } catch {
                            // Capture before outer cleanup removes the hotspot configuration.
                            networkDiagnostics.recordSnapshot(phase: "tcp-connect-failed-before-cleanup", force: true)
                            networkDiagnostics.log("TCP 建连失败现场", detail: "endpoint=\(endpoint)\nerror=\(Self.formatErrorDetail(error))\nSSID_not_read_or_required; snapshot_does_not_prove_AP_authentication_or_service_failure")
                            throw error
                        }
                    }
                    connectedTransport = client
                } catch {
                    await transport.close()
                    await client?.close()
                    try checkTarget()
                    if pathRetryCount >= 3 { throw error }
                    diagnostics.log("TCP 未连通，保留热点供手动连接", detail: "error=\(error.localizedDescription); fileListRequested=false")
                    try await waitForManualWifiJoin(credentials, ble: ble, hotspot: hotspot, requireLANRejoin: true, diagnostics: diagnostics)
                }
            }
            guard let transport = connectedTransport else { throw DeviceWifiError.unreachable }
            try checkTarget()
            state = .fetchingList
            listedNames = try await withPathRecovery(transport) { try await $0.fileList() }
            let watermarkBinding = PhotoCaptureWatermarkStore.shared.bind(fileNames: listedNames,
                account: identity.accountID, device: targetID.uuidString)
            diagnostics.log("关联拍照水印设置", detail: watermarkBinding)
            remainingFileCount = listedNames.count
            diagnostics.log("TCP 文件列表已获取", detail: "endpoint=\(endpoint) count=\(listedNames.count); BLE_ready_not_required_during_transfer")
            var finalProcessingReconnected = false
            for (index, name) in listedNames.enumerated() {
                try checkTarget()
                state = .downloading(current: index + 1, total: listedNames.count, fileName: name)
                let entry = try inbox.prepare(targetID: targetID, fileName: name, accountID: identity.accountID)
                do {
                    diagnostics.log("开始传输原始文件", detail: "file=\(name) fileTimeout=\(AlbumTransferPolicy.fileTimeout)s; read_and_write_use_file_deadline", direction: .sent)
                    var restartingFile = false
                    let destination = inbox.fileURL(for: entry)
                    let bytes = try await withPathRecovery(client ?? transport) { activeTransport in
                        // Retry only this incomplete file. Fully published originals and
                        // the original file list remain untouched.
                        if restartingFile {
                            let partial = destination.appendingPathExtension("partial")
                            if FileManager.default.fileExists(atPath: partial.path) {
                                try FileManager.default.removeItem(at: partial)
                            }
                        }
                        restartingFile = true
                        return try await activeTransport.downloadFile(named: name, to: destination)
                    }
                    remainingFileCount = max(0, (remainingFileCount ?? 0) - 1)
                    diagnostics.log("原始文件已完整落盘", detail: "file=\(name) bytes=\(bytes) original=\(inbox.fileURL(for: entry).path)")
                } catch {
                    record(name, index: index + 1, total: listedNames.count, stage: "tcpDownload", error: error)
                    throw error // A broken stream cannot safely continue with another request.
                }
                try checkTarget()
                // The network monitor owns only its replacement connection. Local
                // processing retains its cancellation/identity rules independently.
                let processingTransport = client ?? transport
                let retryBudget = max(0, 3 - pathRetryCount)
                let processingRecovery = Task { @MainActor () -> (Gen1MediaTCPClient, Int) in
                    var active = processingTransport
                    var attempts = 0
                    var failure: Error?
                    while !Task.isCancelled, ble.isGen1MediaImportCurrent(identity) {
                        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
                        guard !Task.isCancelled else { break }
                        if failure == nil { failure = await active.processingRecoveryError() }
                        guard let error = failure else { continue }
                        guard DeviceWifiManager.gen1HasClientIPv4 else {
                            diagnostics.log("算法期间离开眼镜网段，停止 TCP 保活重连", detail: "phase=localProcessing keptHotspot=true stabilizeCancelled=false noApply=true")
                            break
                        }
                        guard attempts < retryBudget else {
                            diagnostics.log("算法期间 TCP 保活重试耗尽", detail: "phase=localProcessing attempts=\(attempts) keptHotspot=true stabilizeCancelled=false error=\(Self.formatErrorDetail(error))")
                            break
                        }
                        let delays: [UInt64] = [300_000_000, 800_000_000, 1_500_000_000]
                        do { try await Task.sleep(nanoseconds: delays[attempts]) } catch { break }
                        guard !Task.isCancelled, ble.isGen1MediaImportCurrent(identity), DeviceWifiManager.gen1HasClientIPv4 else { break }
                        attempts += 1
                        diagnostics.log("算法期间静默重连 TCP", detail: "phase=localProcessing keepaliveRetryIndex=\(attempts) remainingSessionBudget=\(retryBudget) selectedIPv4=\(WifiDiagnosticSession.captureInterfaces().selectedIPv4 ?? "none") keptHotspot=true stabilizeCancelled=false noApply=true noOpenHotspot=true noFileList=true noRedownload=true error=\(Self.formatErrorDetail(error))")
                        await active.close()
                        let replacement = Gen1MediaTCPClient(host: "192.168.4.1")
                        do {
                            try await replacement.connect()
                            active = replacement
                            failure = nil
                            diagnostics.log("算法期间 TCP 保活恢复", detail: "phase=localProcessing keepaliveRetryIndex=\(attempts) heartbeatResumed=true stabilizeCancelled=false")
                        } catch {
                            // Preserve its terminal error for the next transfer/finish.
                            active = replacement
                            failure = error
                            let recoverable = await replacement.canRetryAfterPathChange(error)
                            if Task.isCancelled || !recoverable { break }
                        }
                    }
                    return (active, attempts)
                }
                do {
                    _ = try await commitGen1File(entry, inbox: inbox, library: library, autoSave: autoSave, validateOwnership: checkTarget)
                    importedNames.append(name)
                } catch { record(name, index: index + 1, total: listedNames.count, stage: "importToLibrary", error: error) }
                processingRecovery.cancel()
                let recovered = await processingRecovery.value
                client = recovered.0
                pathRetryCount += recovered.1
                // No confirmed cross-session semantics for the batch-end command.
                if index == listedNames.count - 1, recovered.1 > 0 { finalProcessingReconnected = true }
                try checkTarget()
            }
            try checkTarget()
            state = .finishing
            // Match Android: batch completion once, not a deletion ACK after each file.
            let finishingTransport = client ?? transport
            do {
                if finalProcessingReconnected {
                    transferFinishWarning = true
                    diagnostics.log("最终文件处理期间已重连，不跨 TCP 会话重发结束指令", detail: "imported=\(importedNames.count) listed=\(listedNames.count) transferCompleteUnconfirmed=true next=closeTCP_then_ownedHotspotCleanup")
                } else {
                    try hotspot.prepareForTransferCompletion()
                    try await finishingTransport.finishTransfer()
                }
            } catch {
                hotspot.transferCompletionFailed()
                try checkTarget()
                let recoverable = await finishingTransport.canRetryAfterPathChange(error)
                guard AlbumTransferPolicy.canReportSavedFilesAfterFinishError(
                    listed: listedNames.count, imported: importedNames.count,
                    failed: failures.count, recoverableNetworkError: recoverable
                ) else { throw error }
                transferFinishWarning = true
                diagnostics.log("全部文件已保存，传输结束指令发送失败", detail: "imported=\(importedNames.count) listed=\(listedNames.count) stage=transferComplete allFilesCommitted=true completionCommandDelivery=unconfirmed resendOnNewTCP=false nextStage=closeTCPThen0x38 error=\(Self.formatErrorDetail(error))")
            }
        } catch {
            finalError = ble.isGen1MediaImportCurrent(identity) ? error : Gen1APImportError.targetChanged
            if finalError is ManualWifiJoinExit {
                diagnostics.log("准备重新开启热点", detail: "endpoint=\(endpoint) cleanupBeforeRestart=true")
            } else if finalError is CancellationError {
                diagnostics.log("导入已取消", detail: "endpoint=\(endpoint) imported=\(importedNames.count) nextStage=hotspotCleanup")
            } else {
                diagnostics.log("导入流程失败", detail: "endpoint=\(endpoint) imported=\(importedNames.count) error=\(finalError!.localizedDescription)")
            }
        }

        // Finish all cleanup before publishing a terminal state or accepting a retry.
        state = .finishing
        await client?.close()
        isClosingGen1Hotspot = true
        diagnostics.log("TCP 已关闭，先等待设备热点收尾", detail: "cleanupOrder=closeTCP,waitNormalShutdownOrAbnormal0x38,removePhoneConfiguration")
        let cleanupPending = await hotspot.close() == .pending
        if let ssid, !cleanupPending {
            diagnostics.log("设备热点收尾等待结束，清理手机配置", detail: "deviceCleanupPending=\(cleanupPending) removeReason=importSessionEnded")
            DeviceWifiManager.disconnect(from: ssid)
        }
        isClosingGen1Hotspot = false
        identityWatch.cancel()
        if !failures.isEmpty {
            lastFailureReport = MediaImportFailureReport(
                startedAt: startedAt, deviceSN: deviceSN, deviceReady: ble.isReady,
                expectedFileCount: expectedFileCount, wifiSSID: ssid ?? "",
                httpBaseURL: endpoint, totalListedFiles: listedNames.count,
                importedCount: importedNames.count, purgedCount: 0,
                failedPhotoCount: failedPhotos, failedVideoCount: failedVideos,
                importedFileNames: importedNames, listedFileNames: listedNames, failureRecords: failures,
                credentialSource: "Gen1 0x37", transportName: "TCP"
            )
        }
        if finalError is ManualWifiJoinExit, !cleanupPending, !Task.isCancelled,
           ble.isGen1MediaImportCurrent(identity) {
            // The old identity is ended by defer before the next import begins.
            restartGen1ImportAfterCleanup = true
            state = .idle
        } else if finalError is ManualWifiJoinExit {
            state = .failed(cleanupPending ? Gen1APImportError.hotspotCleanupPending.localizedDescription
                            : Gen1APImportError.targetChanged.localizedDescription)
        } else if finalError is CancellationError {
            if cleanupPending {
                state = .failed(Gen1APImportError.hotspotCleanupPending.localizedDescription)
            } else if importedNames.isEmpty {
                state = .idle
            } else {
                state = .completed(imported: importedNames.count, failedPhotos: failedPhotos, failedVideos: failedVideos)
            }
        } else if let finalError {
            let cleanupDetail = cleanupPending ? "\n\(Gen1APImportError.hotspotCleanupPending.localizedDescription)" : ""
            state = .failed(L10n.t("已导入 \(importedNames.count) 项。\(finalError.localizedDescription)；已下载完整的原件保留在手机，可再次导入恢复。\(cleanupDetail)", "Imported \(importedNames.count) item(s). \(finalError.localizedDescription). Completed originals are retained on this phone for recovery.\(cleanupDetail)"))
        } else if transferFinishWarning {
            let cleanupDetail = cleanupPending
                ? L10n.t("眼镜热点关闭尚未确认，暂不能再次导入或升级，请稍后重试。", "Hotspot shutdown is not yet confirmed. Wait before importing or upgrading again.")
                : L10n.t("眼镜热点已确认关闭。", "The glasses hotspot has been confirmed closed.")
            completionNotice = L10n.t(
                "已导入 \(importedNames.count) 项，文件已保存在 App 相册，无需重复导入。设备传输结束通知未确认。\(cleanupDetail)",
                "Imported \(importedNames.count) item(s), saved in the app album. No need to import them again. The device transfer-end notification is unconfirmed. \(cleanupDetail)"
            )
            diagnostics.log("文件导入完成，附带设备收尾提示", detail: "imported=\(importedNames.count) transferCompleteUnconfirmed=true hotspotCleanupPending=\(cleanupPending) nextImportBlocked=\(cleanupPending)")
            state = .completed(imported: importedNames.count)
        } else if cleanupPending {
            completionNotice = L10n.t(
                "已导入 \(importedNames.count) 项，文件已保存在 App 相册，无需重复导入。眼镜热点关闭尚未确认，暂不能再次导入、升级或拍摄，请稍后重试。",
                "Imported \(importedNames.count) item(s), saved in the app album. No need to import them again. Hotspot shutdown is not yet confirmed. Wait before importing, upgrading, or capturing again."
            )
            diagnostics.log("文件已保存，热点关闭未确认", detail: "imported=\(importedNames.count) failedPhotos=\(failedPhotos) failedVideos=\(failedVideos) hotspotCleanupPending=true importFailure=false")
            state = .completed(imported: importedNames.count, failedPhotos: failedPhotos, failedVideos: failedVideos)
        } else {
            state = .completed(imported: importedNames.count, failedPhotos: failedPhotos, failedVideos: failedVideos)
        }
    }

    /// 热点切换允许有限重连；恢复后仍须有对应账号设备卡片。
    private func requireAvailableDevice(_ ble: AstraA1BleManager) async throws {
        try Task.checkCancellation()
        guard await waitUntilBLEReady(ble, timeout: 20) else {
            throw MediaImportError.deviceUnavailable
        }
        try Task.checkCancellation()
    }

    private func waitUntilBLEReady(_ ble: AstraA1BleManager, timeout: TimeInterval) async -> Bool {
        if ble.isReady { return ble.isDeviceAvailable }
        let deadline = Date().addingTimeInterval(timeout)
        print("\(logTag) waiting BLE ready, timeout=\(timeout)s state=\(String(describing: ble.connectionState))")
        while Date() < deadline {
            if Task.isCancelled { return false }
            if ble.isReady {
                print("\(logTag) BLE ready, available=\(ble.isDeviceAvailable)")
                return ble.isDeviceAvailable
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        print("\(logTag) wait BLE ready timeout, isReady=\(ble.isReady)")
        return ble.isDeviceAvailable
    }

    private func deleteDeviceFilesWithRetry(ble: AstraA1BleManager, fileNames: [String]) async -> Int {
        guard !fileNames.isEmpty else { return 0 }
        var remaining = fileNames
        for attempt in 1...3 {
            guard await waitUntilBLEReady(ble, timeout: 10) else { return 0 }
            do {
                try await ble.deleteImportedFiles(remaining)
                print("\(logTag) deleted device files ok count=\(remaining.count) attempt=\(attempt)")
                return remaining.count
            } catch {
                print("\(logTag) delete attempt \(attempt)/3 failed: \(error.localizedDescription) files=\(remaining)")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        print("\(logTag) delete exhausted, leftover on device: \(remaining)")
        return 0
    }

    func resetStatus() {
        if case .completed = state { state = .idle }
        if case .failed = state { state = .idle }
    }

    func clearFailureReport() {
        lastFailureReport = nil
    }

    // MARK: - Wi-Fi 凭据获取

    private struct ResolvedWifi {
        let ssid: String
        let password: String
        let httpAddress: String
    }

    /// 每次：toopenwifi → 解析本次 wificonfig（不走缓存）。
    private func resolveWifiCredential(ble: AstraA1BleManager) async throws -> ResolvedWifi {
        let config = try await ble.openWifiAndWaitConfig(purpose: .fileImport)
        guard let ssid = config.ssid?.trimmingCharacters(in: .whitespacesAndNewlines), !ssid.isEmpty else {
            throw MediaImportError.message(L10n.t("未从眼镜获取到 Wi-Fi 名称", "Failed to get Wi-Fi name from glasses"))
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

    // MARK: - HTTP

    private func fetchMediaFileList(ble: AstraA1BleManager, baseURL: String, expectedCount: Int) async throws -> [String] {
        var lastError: Error?
        for attempt in 1...8 {
            try await requireAvailableDevice(ble)
            do {
                let html = try await GlassesHTTPClient.fetchText(baseURL: baseURL)
                print("\(logTag) html length=\(html.count)")
                if html.count <= 500 {
                    print("\(logTag) html body: \(html)")
                } else {
                    print("\(logTag) html preview: \(html.prefix(500))")
                }
                let names = Self.parseMediaFileNames(from: html)
                if !names.isEmpty {
                    return names
                }
                guard GlassesMediaDirectory.isDirectoryListing(html) else {
                    throw MediaImportError.message(L10n.t("眼镜返回的内容不是有效文件目录", "The glasses returned an invalid file directory"))
                }
                if expectedCount == 0 || attempt == 8 {
                    DebugLogStore.logWiFi("相册导入：眼镜目录为空", detail: "url=\(baseURL) cachedCount=\(expectedCount) attempts=\(attempt) HTTPDirectoryVerified=true mediaFiles=0")
                    return []
                }
                // A nonzero BLE count may be stale or precede filesystem publication.
                // Give the device time to publish files before accepting empty.
                throw MediaImportError.message(L10n.t("眼镜目录暂未发现照片或视频", "No photos or videos in the glasses directory yet"))
            } catch {
                if Self.isWifiConnectivityFailure(error) {
                    throw error
                }
                lastError = error
                print("\(logTag) fetch list \(attempt)/8 error: \(error.localizedDescription)")
                if attempt < 8 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }

        throw lastError ?? MediaImportError.message(L10n.t("获取文件列表失败", "Failed to get file list"))
    }

    private func downloadFile(ble: AstraA1BleManager, baseURL: String, fileName: String) async throws -> Data {
        var lastError: Error?
        for attempt in 1...3 {
            try await requireAvailableDevice(ble)
            do {
                return try await GlassesHTTPClient.fetchData(
                    baseURL: baseURL, fileName: fileName,
                    timeout: AlbumTransferPolicy.fileTimeout,
                    connectTimeout: AlbumTransferPolicy.fileTimeout
                )
            } catch GlassesHTTPError.emptyBody {
                // 眼镜返回 Content-Length: 0，文件本身为空，重试无意义
                throw GlassesHTTPError.emptyBody
            } catch {
                if Self.isWifiConnectivityFailure(error) {
                    throw error
                }
                lastError = error
                print("\(logTag) download \(fileName) \(attempt)/3 error: \(error.localizedDescription)")
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError ?? MediaImportError.message(L10n.t("下载失败: \(fileName)", "Download failed: \(fileName)"))
    }

    private static func isWifiConnectivityFailure(_ error: Error) -> Bool {
        if case MediaImportError.deviceUnavailable = error { return true }
        if error is CancellationError { return true }
        if error is DeviceWifiError { return true }
        return (error as? GlassesHTTPError)?.isConnectivityFailure == true
    }

    static func parseMediaFileNames(from html: String) -> [String] {
        GlassesMediaDirectory.fileNames(from: html)
    }

    private static func isVideoFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
    }

    private static func recordFailure(
        fileName: String,
        fileIndex: Int,
        totalFiles: Int,
        stage: String,
        baseURL: String,
        bytesDownloaded: Int?,
        error: Error,
        failureRecords: inout [MediaImportFailureRecord],
        failedPhotoCount: inout Int,
        failedVideoCount: inout Int
    ) {
        if isVideoFileName(fileName) {
            failedVideoCount += 1
        } else {
            failedPhotoCount += 1
        }

        failureRecords.append(
            MediaImportFailureRecord(
                fileName: fileName,
                mediaType: isVideoFileName(fileName) ? "video" : "photo",
                fileIndex: fileIndex,
                totalFiles: totalFiles,
                stage: stage,
                baseURL: baseURL,
                bytesDownloaded: bytesDownloaded,
                errorDetail: formatErrorDetail(error)
            )
        )
        print("[MediaImport] \(fileName) 处理失败，阶段=\(stage)，保留设备文件")
        print(formatErrorDetail(error))
    }

    private static func formatErrorDetail(_ error: Error, indent: String = "  ") -> String {
        let nsError = error as NSError
        var lines: [String] = [
            "\(indent)swiftType: \(String(reflecting: type(of: error)))",
            "\(indent)localizedDescription: \(error.localizedDescription)",
            "\(indent)domain: \(nsError.domain)",
            "\(indent)code: \(nsError.code)",
        ]

        for (key, value) in nsError.userInfo {
            if key == NSUnderlyingErrorKey, let underlying = value as? Error {
                lines.append("\(indent)underlyingError:")
                lines.append(formatErrorDetail(underlying, indent: indent + "  "))
            } else {
                lines.append("\(indent)userInfo[\(key)]: \(value)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// 眼镜端文件已损坏、本地无法打开/解码时，直接从设备删除，避免反复重试。
    private static func shouldDeleteUnopenableFile(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let unrecoverableHints = [
            "cannot open",
            "cannot decode",
            "cannot decode raw data",
            "invalid image",
            "failed to load",
        ]
        return unrecoverableHints.contains { message.contains($0) }
    }
}

private enum MediaImportError: LocalizedError {
    case deviceUnavailable
    case message(String)
    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: return L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
        case .message(let text): return text
        }
    }
}
