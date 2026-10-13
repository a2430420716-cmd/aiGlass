import Combine
import Foundation
import UIKit

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

@MainActor
final class MediaImportManager: ObservableObject {
    static let shared = MediaImportManager()

    @Published private(set) var state: MediaImportState = .idle
    @Published private(set) var lastFailureReport: MediaImportFailureReport?
    @Published private(set) var pendingGen1RecoveryCount = 0
    @Published private var isClosingGen1Hotspot = false

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
        switch state {
        case .idle:
            return ""
        case .openingWifi:
            return L10n.t("正在开启眼镜热点...", "Turning on glasses hotspot...")
        case .connectingWifi:
            return L10n.t("正在连接眼镜 Wi-Fi...", "Connecting to glasses Wi-Fi...")
        case .fetchingList:
            return L10n.t("正在获取文件列表...", "Fetching file list...")
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
            return L10n.t("已导入 \(imported) 项", "Imported \(imported) item(s)")
        case .failed(let message):
            return message
        }
    }

    /// 启动导入。任务由本管理器持有，切换页面/销毁视图都不会中断，只有强杀 App 才会终止。
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
        importTask = Task { [weak self] in
            await self?.startImport(
                ble: ble,
                library: library,
                expectedFileCount: expectedFileCount,
                autoSaveToPhotoLibrary: autoSaveToPhotoLibrary
            )
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
                deviceEvidence: { diagnostics.deviceEvidence }
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
                await deleteDeviceFilesWithRetry(ble: ble, fileNames: uniqueDeletes)
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
                // BLE 暂未 ready：本地先扣掉已导入数量，避免 UI 仍显示旧 pending。
                ble.noteImportedMediaFiles(count: importedNames.count + purgedFromDeviceCount)
                print("\(logTag) BLE not ready after closewifi, applied local pending decrement")
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
            state = .failed(error.localizedDescription)
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
        let item = try await library.importGen1Original(fileURL: inbox.fileURL(for: entry), fileName: entry.fileName)
        try validateOwnership()
        if autoSave {
            do {
                try await SystemPhotoLibrarySaver.save(fileURL: library.originalURL(for: item), isVideo: item.isVideo)
            } catch {
                DebugLogStore.logWiFi("一代：保存系统相册失败，App 原件已保留", detail: "file=\(entry.fileName) error=\(error.localizedDescription)")
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
        catch { DebugLogStore.logWiFi("一代：待恢复目录清理失败", detail: "file=\(entry.fileName) error=\(error.localizedDescription)") }
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
                    DebugLogStore.logWiFi("一代：本地恢复失败，原件保留并继续下一项", detail: "file=\(entry.fileName) error=\(error.localizedDescription)")
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
            diagnostics.log("一代：文件导入失败，保留手机现有原始数据", detail: "file=\(name) stage=\(stage) error=\(error.localizedDescription)")
        }

        state = .fetchingList
        diagnostics.log("一代：开始 AP 相册导入", detail: "target=\(targetID) transport=TCP:8556")
        do {
            // License activation may need internet. Finish this while still on the
            // phone's normal network, before switching to the glasses' local AP.
            let licensed = await Task.detached(priority: .utility) {
                PixSmartImageStabilizer.prewarmLicense()
            }.value
            diagnostics.log("一代：视频防抖预鉴权结束", detail: "licensed=\(licensed); failure_keeps_original_video")
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
            let gateway = try await DeviceWifiManager.connectGen1(
                ssid: credentials.ssid, password: credentials.password,
                diagnosticID: diagnostics.id, deviceEvidence: { diagnostics.deviceEvidence }
            )
            try checkTarget()
            endpoint = "tcp://\(gateway):8556"
            let transport = Gen1MediaTCPClient(host: gateway)
            client = transport
            try await transport.connect()
            try checkTarget()
            state = .fetchingList
            listedNames = try await transport.fileList()
            remainingFileCount = listedNames.count
            diagnostics.log("一代：TCP 文件列表已获取", detail: "endpoint=\(endpoint) count=\(listedNames.count); BLE_ready_not_required_during_transfer")
            for (index, name) in listedNames.enumerated() {
                try checkTarget()
                state = .downloading(current: index + 1, total: listedNames.count, fileName: name)
                let entry = try inbox.prepare(targetID: targetID, fileName: name, accountID: identity.accountID)
                do {
                    diagnostics.log("一代：开始传输原始文件", detail: "file=\(name) fileTimeout=\(AlbumTransferPolicy.fileTimeout)s; read_and_write_use_file_deadline", direction: .sent)
                    let bytes = try await transport.downloadFile(named: name, to: inbox.fileURL(for: entry))
                    remainingFileCount = max(0, (remainingFileCount ?? 0) - 1)
                    diagnostics.log("一代：原始文件已完整落盘", detail: "file=\(name) bytes=\(bytes) original=\(inbox.fileURL(for: entry).path)")
                } catch {
                    record(name, index: index + 1, total: listedNames.count, stage: "tcpDownload", error: error)
                    throw error // A broken stream cannot safely continue with another request.
                }
                try checkTarget()
                do {
                    _ = try await commitGen1File(entry, inbox: inbox, library: library, autoSave: autoSave, validateOwnership: checkTarget)
                    importedNames.append(name)
                } catch { record(name, index: index + 1, total: listedNames.count, stage: "importToLibrary", error: error) }
            }
            try checkTarget()
            state = .finishing
            // Match Android: batch completion once, not a deletion ACK after each file.
            try await transport.finishTransfer()
        } catch {
            finalError = ble.isGen1MediaImportCurrent(identity) ? error : Gen1APImportError.targetChanged
            diagnostics.log("一代：导入流程失败", detail: "endpoint=\(endpoint) imported=\(importedNames.count) error=\(finalError!.localizedDescription)")
        }

        // Finish all cleanup before publishing a terminal state or accepting a retry.
        state = .finishing
        await client?.close()
        if let ssid { DeviceWifiManager.disconnect(from: ssid) }
        isClosingGen1Hotspot = true
        let cleanupPending = await hotspot.close() == .pending
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
        if let finalError {
            let cleanupDetail = cleanupPending ? "\n\(Gen1APImportError.hotspotCleanupPending.localizedDescription)" : ""
            state = .failed(L10n.t("已导入 \(importedNames.count) 项。\(finalError.localizedDescription)；已下载完整的原件保留在手机，可再次导入恢复。\(cleanupDetail)", "Imported \(importedNames.count) item(s). \(finalError.localizedDescription). Completed originals are retained on this phone for recovery.\(cleanupDetail)"))
        } else if cleanupPending {
            state = .failed(L10n.t("已导入 \(importedNames.count) 项。\(Gen1APImportError.hotspotCleanupPending.localizedDescription)", "Imported \(importedNames.count) item(s). \(Gen1APImportError.hotspotCleanupPending.localizedDescription)"))
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

    private func deleteDeviceFilesWithRetry(ble: AstraA1BleManager, fileNames: [String]) async {
        guard !fileNames.isEmpty else { return }
        var remaining = fileNames
        for attempt in 1...3 {
            guard await waitUntilBLEReady(ble, timeout: 10) else { return }
            do {
                try await ble.deleteImportedFiles(remaining)
                print("\(logTag) deleted device files ok count=\(remaining.count) attempt=\(attempt)")
                return
            } catch {
                print("\(logTag) delete attempt \(attempt)/3 failed: \(error.localizedDescription) files=\(remaining)")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        print("\(logTag) delete exhausted, leftover on device: \(remaining)")
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
                throw MediaImportError.message(L10n.t("HTTP 已连通但文件列表为空", "Connected but file list is empty"))
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

        if expectedCount > 0 {
            throw MediaImportError.message(L10n.t("无法从眼镜下载文件列表。请确认：1) 已加入 ble_wifi_test 热点；2) 设置中已允许「本地网络」权限", "Unable to download file list. Check: 1) Joined the glasses hotspot; 2) Local Network permission is allowed"))
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
        var names: [String] = []

        let hrefPatterns = [
            #"href\s*=\s*["']([^"']+)["']"#,
            #"href\s*=\s*([^\s>"]+\.(?:jpg|jpeg|png|heic|mp4|mov))"#,
        ]
        for pattern in hrefPatterns {
            appendMatches(from: html, pattern: pattern, into: &names)
        }

        let textPattern = #"([A-Za-z0-9_\-\.]+\.(?:jpg|jpeg|png|heic|mp4|mov))"#
        appendMatches(from: html, pattern: textPattern, into: &names)

        return names
    }

    private static func appendMatches(from html: String, pattern: String, into names: inout [String]) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, options: [], range: range) {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: html) else { continue }
            guard let normalized = normalizeMediaFileName(String(html[nameRange])),
                  !names.contains(normalized) else { continue }
            names.append(normalized)
        }
    }

    private static func normalizeMediaFileName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return nil }
        if let query = name.firstIndex(of: "?") {
            name = String(name[..<query])
        }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        let lower = name.lowercased()
        if lower.contains("_thumb") || lower.contains("thumb.jpg") { return nil }
        guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png")
            || lower.hasSuffix(".heic") || lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") else {
            return nil
        }
        return name
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
