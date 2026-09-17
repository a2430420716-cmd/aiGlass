import AVFoundation
import Combine
import Foundation

enum AIRecordingImportState: Equatable {
    case idle
    case openingWifi
    case connectingWifi
    case fetchingList
    case downloading(current: Int, total: Int, fileName: String)
    case finishing
    case completed(imported: Int, failed: Int)
    case failed(String)
}

/// AI 录音专用 Wi‑Fi 导入（对齐 Android FileImportManager.recordingOnly）。
@MainActor
final class AIRecordingImportManager: ObservableObject {
    static let shared = AIRecordingImportManager()

    @Published private(set) var state: AIRecordingImportState = .idle
    /// 删除失败后残留在眼镜上的录音名；进页用来恢复导入提示。
    @Published private(set) var leftoverDeviceFileNames: [String] = []

    private let logTag = "[AIRecordingImport]"
    private let leftoverKey = "ai.recording.leftover.device.files"
    private var connectedSSID: String?
    private var importTask: Task<Void, Never>?

    var leftoverDeviceFileCount: Int { leftoverDeviceFileNames.count }

    private init() {
        leftoverDeviceFileNames = UserDefaults.standard.stringArray(forKey: leftoverKey) ?? []
    }

    var isImporting: Bool {
        switch state {
        case .idle, .completed, .failed:
            return false
        default:
            return true
        }
    }

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
            return L10n.t("正在开启眼镜热点...", "Enabling glasses hotspot...")
        case .connectingWifi:
            return L10n.t("正在连接眼镜 Wi-Fi...", "Connecting to glasses Wi-Fi...")
        case .fetchingList:
            return L10n.t("正在获取录音列表...", "Fetching recording list...")
        case .downloading(let current, let total, _):
            return L10n.t("正在导入 \(current)/\(total)", "Importing \(current)/\(total)")
        case .finishing:
            return L10n.t("正在完成导入...", "Finishing import...")
        case .completed(let imported, let failed):
            if failed > 0 {
                return L10n.t("已导入 \(imported) 项，部分失败", "Imported \(imported) item(s), some failed")
            }
            return L10n.t("已导入 \(imported) 项", "Imported \(imported) item(s)")
        case .failed(let message):
            return message
        }
    }

    /// 启动录音导入。任务由本管理器持有，切页不中断。
    func beginImport(
        ble: AstraA1BleManager,
        store: AIRecordingStore,
        expectedFileCount: Int = 0
    ) {
        guard !isImporting, importTask == nil else { return }
        if MediaImportManager.shared.isImporting {
            state = .failed(L10n.t("相册正在导入，请稍后再试", "Album import in progress, try again later"))
            return
        }
        importTask = Task { [weak self] in
            await self?.startImport(ble: ble, store: store, expectedFileCount: expectedFileCount)
            self?.importTask = nil
        }
    }

    private func startImport(
        ble: AstraA1BleManager,
        store: AIRecordingStore,
        expectedFileCount: Int
    ) async {
        guard !isImporting else { return }
        guard ble.isReady else {
            state = .failed(L10n.t("请先连接眼镜设备", "Please connect glasses first"))
            return
        }
        guard !ble.isBatteryTooLowForMedia else {
            state = .failed(ble.lowBatteryMediaMessage)
            return
        }

        DebugLogStore.logWiFi(
            "录音导入：开始 Wi-Fi 流程",
            detail: "expectedFileCount=\(expectedFileCount)\nbleReady=\(ble.isReady)"
        )

        do {
            state = .openingWifi
            print("\(logTag) Step1: toopenwifi(fileImport) → wificonfig")
            let wifi = try await resolveWifiCredential(ble: ble)
            connectedSSID = wifi.ssid
            print("\(logTag) wifi ssid=\(wifi.ssid) http=\(wifi.httpAddress)")
            DebugLogStore.logWiFi(
                "录音导入：热点配置就绪",
                detail: "ssid=\(wifi.ssid)\npasswordEmpty=\(wifi.password.isEmpty)\nhttp=\(wifi.httpAddress)",
                direction: .received
            )

            state = .connectingWifi
            print("\(logTag) Step2: join hotspot")
            try await DeviceWifiManager.connect(
                ssid: wifi.ssid,
                password: wifi.password,
                probeBaseURL: wifi.httpAddress
            )
            DebugLogStore.logWiFi(
                "录音导入：热点连接成功",
                detail: "ssid=\(wifi.ssid)\nhttp=\(wifi.httpAddress)",
                direction: .received
            )

            state = .fetchingList
            var baseURL = wifi.httpAddress
            if baseURL.isEmpty {
                baseURL = (try? await ble.getDownloadWorkPath()) ?? ""
            }
            if baseURL.isEmpty { baseURL = "http://192.168.0.1/" }
            if !baseURL.hasSuffix("/") { baseURL += "/" }
            let listURL = baseURL + "airecord/"
            print("\(logTag) work path=\(baseURL) list=\(listURL)")

            print("\(logTag) Step3: GET airecord/ list")
            let fileNames = try await fetchAACFileList(baseURL: listURL, expectedCount: expectedFileCount)
            print("\(logTag) aac files=\(fileNames)")

            var importedNames: [String] = []
            var filesToDeleteOnDevice: [String] = []
            var failedCount = 0

            if fileNames.isEmpty {
                state = .finishing
                _ = await finishOnDevice(ble: ble, transferOK: true, deleteNames: [])
                // 无预期时才清零；有预期却空列表应在 fetch 阶段已抛错。
                if expectedFileCount <= 0 {
                    ble.noteImportedRecordingFiles()
                }
                state = .completed(imported: 0, failed: 0)
                print("\(logTag) done empty list")
                return
            }

            for (index, name) in fileNames.enumerated() {
                state = .downloading(current: index + 1, total: fileNames.count, fileName: name)
                do {
                    let data = try await downloadFile(baseURL: listURL, fileName: name)
                    let savedURL = try saveAACFile(data: data, fileName: name, store: store)
                    let durationMs = await Self.readDurationMs(url: savedURL)
                    if store.addRecording(
                        fileURL: savedURL,
                        fileName: name,
                        durationMs: durationMs,
                        playable: true
                    ) != nil {
                        importedNames.append(name)
                        filesToDeleteOnDevice.append(name)
                        print("\(logTag) imported \(name) bytes=\(data.count) durationMs=\(durationMs)")
                    } else {
                        // 重复路径：仍删设备端，避免反复导入
                        try? FileManager.default.removeItem(at: savedURL)
                        filesToDeleteOnDevice.append(name)
                        print("\(logTag) duplicate skip store for \(name), still delete device copy")
                    }
                } catch GlassesHTTPError.emptyBody {
                    filesToDeleteOnDevice.append(name)
                    print("\(logTag) \(name) empty, schedule delete")
                } catch {
                    if Self.isWifiConnectivityFailure(error) {
                        print("\(logTag) Wi-Fi unavailable during recording download, abort batch")
                        throw error
                    }
                    failedCount += 1
                    print("\(logTag) \(name) failed, keep device file: \(error.localizedDescription)")
                }
            }

            state = .finishing
            let uniqueDeletes = Array(Set(filesToDeleteOnDevice))
            let transferOK = failedCount == 0
            let deleteSucceeded = await finishOnDevice(
                ble: ble,
                transferOK: transferOK,
                deleteNames: uniqueDeletes
            )

            if await waitUntilBLEReady(ble, timeout: 20) {
                ble.queryPendingImportFiles()
            } else if deleteSucceeded {
                ble.noteImportedRecordingFiles(count: importedNames.count)
                print("\(logTag) BLE not ready after closewifi, applied local recording pending decrement")
            }

            // 成功删完才清零；失败则记残留，进页仍显示导入条。
            if failedCount == 0, deleteSucceeded {
                clearLeftoverDeviceFiles()
                ble.noteImportedRecordingFiles()
            } else if !uniqueDeletes.isEmpty, !deleteSucceeded {
                rememberLeftoverDeviceFiles(uniqueDeletes)
                ble.applyPendingRecordingImportCount(uniqueDeletes.count)
            }

            state = .completed(imported: importedNames.count, failed: failedCount)
            print("\(logTag) done imported=\(importedNames.count) failed=\(failedCount) deleteOK=\(deleteSucceeded)")
            DebugLogStore.logWiFi(
                "录音导入：Wi-Fi 流程结束",
                detail: "imported=\(importedNames.count)\nfailed=\(failedCount)\ndeleteSucceeded=\(deleteSucceeded)"
            )
        } catch {
            let failedStage = String(describing: state)
            state = .failed(error.localizedDescription)
            print("\(logTag) FAILED: \(error.localizedDescription)")
            DebugLogStore.logWiFi(
                "录音导入：Wi-Fi 流程失败",
                detail: "stage=\(failedStage)\nssid=\(connectedSSID ?? "nil")\nerror=\(error.localizedDescription)",
                direction: .received
            )
            try? await ble.closeWifi()
            disconnectHotspot()
            ble.syncDeviceStatusAfterImport(reason: "recording-import-failed")
        }
    }

    private func finishOnDevice(
        ble: AstraA1BleManager,
        transferOK: Bool,
        deleteNames: [String]
    ) async -> Bool {
        // 对齐安卓 FileImportManager：transferok → deletefile(分批) → closewifi。
        print("\(logTag) Step4: wait BLE ready then transferok=\(transferOK) delete=\(deleteNames.count) names=\(deleteNames)")
        var deleteSucceeded = deleteNames.isEmpty
        if await waitUntilBLEReady(ble, timeout: 30) {
            ble.sendTransferOK(success: transferOK)
            // 安卓 sendTransferOk 后立刻删；给设备一点处理时间。
            try? await Task.sleep(nanoseconds: 250_000_000)
            deleteSucceeded = await deleteDeviceFilesWithRetry(ble: ble, fileNames: deleteNames)
        } else {
            print("\(logTag) BLE not ready after download, skip transferok/delete")
        }
        print("\(logTag) Step5: closewifi deleteSucceeded=\(deleteSucceeded)")
        try? await ble.closeWifi()
        disconnectHotspot()
        // Android recordingOnly 复用同一 FileImportManager，完成后也重置为 STANDBY。
        ble.syncDeviceStatusAfterImport(reason: "recording-import-complete")

        // 热点关闭后 BLE 通常更稳定；首次删除失败时再补删，避免录音留在眼镜。
        if !deleteSucceeded, !deleteNames.isEmpty,
           await waitUntilBLEReady(ble, timeout: 20) {
            print("\(logTag) retry delete after closewifi count=\(deleteNames.count)")
            deleteSucceeded = await deleteDeviceFilesWithRetry(
                ble: ble,
                fileNames: deleteNames
            )
        }
        return deleteSucceeded
    }

    func resetStatus() {
        if case .completed = state { state = .idle }
        if case .failed = state { state = .idle }
    }

    /// 进录音页：有删除残留则恢复 pending，保证导入条能出来。
    func restoreLeftoverPendingIfNeeded(ble: AstraA1BleManager) {
        let leftover = leftoverDeviceFileNames
        guard !leftover.isEmpty else { return }
        if ble.pendingRecordingImportFileCount < leftover.count {
            ble.applyPendingRecordingImportCount(leftover.count)
        }
        print("\(logTag) restore leftover pending count=\(leftover.count) names=\(leftover)")
    }

    private func rememberLeftoverDeviceFiles(_ names: [String]) {
        let unique = Array(Set(names)).sorted()
        leftoverDeviceFileNames = unique
        UserDefaults.standard.set(unique, forKey: leftoverKey)
        print("\(logTag) remember leftover device files count=\(unique.count)")
    }

    private func clearLeftoverDeviceFiles() {
        leftoverDeviceFileNames = []
        UserDefaults.standard.removeObject(forKey: leftoverKey)
        print("\(logTag) cleared leftover device files")
    }

    // MARK: - Wi-Fi

    private struct ResolvedWifi {
        let ssid: String
        let password: String
        let httpAddress: String
    }

    private func resolveWifiCredential(ble: AstraA1BleManager) async throws -> ResolvedWifi {
        let config = try await ble.openWifiAndWaitConfig(purpose: .fileImport)
        guard let ssid = config.ssid?.trimmingCharacters(in: .whitespacesAndNewlines), !ssid.isEmpty else {
            throw AIRecordingImportError.message(L10n.t("未从眼镜获取到 Wi-Fi 名称", "Could not get Wi-Fi name from glasses"))
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

    // MARK: - HTTP / files

    private func fetchAACFileList(baseURL: String, expectedCount: Int) async throws -> [String] {
        var lastError: Error?
        for attempt in 1...8 {
            do {
                let html = try await GlassesHTTPClient.fetchText(baseURL: baseURL)
                print("\(logTag) html length=\(html.count)")
                if html.count <= 800 {
                    print("\(logTag) html body: \(html)")
                } else {
                    print("\(logTag) html preview: \(String(html.prefix(500)))")
                }
                let names = Self.parseAACFileNames(from: html)
                if !names.isEmpty {
                    return names
                }
                // 预期待导入 > 0 却解析为空：多半路径/解析问题或目录未就绪，继续重试。
                if expectedCount > 0 {
                    throw AIRecordingImportError.message(L10n.t("录音目录列表为空，等待设备就绪", "Recording list empty, waiting for device"))
                }
                return []
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
            throw AIRecordingImportError.message(L10n.t("无法从眼镜下载录音列表。请确认已加入眼镜热点并允许本地网络权限", "Cannot download recording list. Join glasses hotspot and allow Local Network access"))
        }
        throw lastError ?? AIRecordingImportError.message(L10n.t("获取录音列表失败", "Failed to fetch recording list"))
    }

    private func downloadFile(baseURL: String, fileName: String) async throws -> Data {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try await GlassesHTTPClient.fetchData(baseURL: baseURL, fileName: fileName)
            } catch GlassesHTTPError.emptyBody {
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
        throw lastError ?? AIRecordingImportError.message(L10n.t("下载失败: \(fileName)", "Download failed: \(fileName)"))
    }

    private static func isWifiConnectivityFailure(_ error: Error) -> Bool {
        if error is DeviceWifiError { return true }
        return (error as? GlassesHTTPError)?.isConnectivityFailure == true
    }

    private func saveAACFile(data: Data, fileName: String, store: AIRecordingStore) throws -> URL {
        let dir = store.recordingsDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = (fileName as NSString).lastPathComponent
        var target = dir.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: target.path) {
            let base = (safeName as NSString).deletingPathExtension
            let ext = (safeName as NSString).pathExtension
            target = dir.appendingPathComponent("\(base)_\(Int(Date().timeIntervalSince1970)).\(ext.isEmpty ? "aac" : ext)")
        }
        try data.write(to: target, options: [.atomic])
        return target
    }

    private func waitUntilBLEReady(_ ble: AstraA1BleManager, timeout: TimeInterval) async -> Bool {
        if ble.isReady { return true }
        let deadline = Date().addingTimeInterval(timeout)
        print("\(logTag) waiting BLE ready, timeout=\(timeout)s")
        while Date() < deadline {
            if ble.isReady { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return ble.isReady
    }

    private func deleteDeviceFilesWithRetry(
        ble: AstraA1BleManager,
        fileNames: [String]
    ) async -> Bool {
        guard !fileNames.isEmpty else { return true }
        // 眼镜录音目录在 airecord/；部分固件要求带路径，部分只认文件名。两种都试。
        let candidates: [[String]] = [
            fileNames,
            fileNames.map { name in
                name.hasPrefix("airecord/") ? name : "airecord/\(name)"
            }
        ]
        for names in candidates {
            for attempt in 1...3 {
                guard ble.isReady else {
                    _ = await waitUntilBLEReady(ble, timeout: 10)
                    continue
                }
                do {
                    try await ble.deleteImportedFiles(names)
                    print("\(logTag) deleted device files ok count=\(names.count) attempt=\(attempt) sample=\(names.first ?? "")")
                    return true
                } catch {
                    print("\(logTag) delete attempt \(attempt)/3 failed names=\(names.first ?? "") err=\(error.localizedDescription)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
        }
        print("\(logTag) delete exhausted, leftover on device: \(fileNames)")
        return false
    }

    static func parseAACFileNames(from html: String) -> [String] {
        var names: [String] = []
        let patterns = [
            #"href\s*=\s*["']([^"']+)["']"#,
            #"href\s*=\s*([^\s>"]+\.aac)"#,
            #"([A-Za-z0-9_\-\.]+\.aac)"#,
        ]
        for pattern in patterns {
            appendMatches(from: html, pattern: pattern, into: &names)
        }
        return names
    }

    private static func appendMatches(from html: String, pattern: String, into names: inout [String]) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, options: [], range: range) {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: html) else { continue }
            guard let normalized = normalizeAACFileName(String(html[nameRange])),
                  !names.contains(normalized) else { continue }
            names.append(normalized)
        }
    }

    private static func normalizeAACFileName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return nil }
        if let query = name.firstIndex(of: "?") {
            name = String(name[..<query])
        }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        let lower = name.lowercased()
        guard lower.hasSuffix(".aac") else { return nil }
        if lower.contains("thumb") { return nil }
        return name
    }

    private static func readDurationMs(url: URL) async -> Int64 {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((seconds * 1000).rounded())
    }
}

private enum AIRecordingImportError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
