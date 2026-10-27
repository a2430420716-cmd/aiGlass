import Foundation
import Combine

/// App 启动后持续记录连接、Wi-Fi、HTTP 与蓝牙双向流量，供调试浮窗展示。
@MainActor
final class DebugLogStore: ObservableObject {
    static let shared = DebugLogStore()

    enum Channel: String {
        case http
        case ble
        /// 眼镜热点申请、系统加入、SSID/IP/TCP 校验、断开与失败收尾。
        case wifi
        /// 进 App 后自动连接 / 重连相关生命周期。
        case connect
    }

    /// 我方发出 vs 服务器/设备回执；`event` 用于连接生命周期。
    enum Direction: String {
        case sent
        case received
        case event

        var label: String {
            switch self {
            case .sent: return "发送"
            case .received: return "回执"
            case .event: return "事件"
            }
        }

        var peerLabel: String {
            switch self {
            case .sent: return "我方 →"
            case .received: return "← 对方"
            case .event: return "连接"
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let date: Date
        let channel: Channel
        let direction: Direction
        let title: String
        let detail: String
    }

    @Published private(set) var httpEntries: [Entry] = []
    @Published private(set) var bleEntries: [Entry] = []
    @Published private(set) var wifiEntries: [Entry] = []
    @Published private(set) var connectEntries: [Entry] = []

    private let maxEntries = 800

    private init() {}

    // MARK: - HTTP

    nonisolated static func logHTTPSent(
        method: String,
        url: String,
        body: String?,
        headers: [String: String]? = nil
    ) {
        let detail = Self.composeHTTPDetail(url: url, headers: headers, body: body, extra: nil)
        Task { @MainActor in
            shared.append(
                channel: .http,
                direction: .sent,
                title: "\(method) \(Self.shortPath(url))",
                detail: detail
            )
        }
    }

    nonisolated static func logHTTPReceived(
        method: String,
        url: String,
        statusCode: Int?,
        body: String?,
        error: String? = nil,
        headers: [String: String]? = nil
    ) {
        var extras: [String] = []
        if let statusCode {
            extras.append("HTTP \(statusCode)")
        }
        if let error, !error.isEmpty {
            extras.append("error: \(error)")
        }
        let detail = Self.composeHTTPDetail(
            url: url,
            headers: headers,
            body: body,
            extra: extras.isEmpty ? nil : extras.joined(separator: " | ")
        )
        let statusText = statusCode.map { " \($0)" } ?? ""
        Task { @MainActor in
            shared.append(
                channel: .http,
                direction: .received,
                title: "\(method)\(statusText) \(Self.shortPath(url))",
                detail: detail
            )
        }
    }

    // MARK: - Translation

    /// Translation WebSocket lifecycle and bounded counters, without audio or transcripts.
    nonisolated static func logTranslation(_ title: String, detail: String = "") {
        Task { @MainActor in
            shared.append(channel: .http, direction: .event, title: "translation \(title)", detail: detail)
        }
    }

    /// 系统分享诊断沿用 HTTP 导出频道，覆盖全部目标应用及系统操作。
    nonisolated static func logShare(_ title: String, detail: String = "") {
        let capturedAt = Date()
        Task { @MainActor in
            shared.append(channel: .http, direction: .event, title: "分享：\(title)", detail: detail, date: capturedAt)
        }
    }

    // MARK: - BLE

    nonisolated static func logBLESent(_ data: Data) {
        let formatted = Self.formatBLE(data)
        Task { @MainActor in
            shared.append(
                channel: .ble,
                direction: .sent,
                title: formatted.title,
                detail: formatted.detail
            )
        }
    }

    nonisolated static func logBLEReceived(_ data: Data) {
        let formatted = Self.formatBLE(data)
        Task { @MainActor in
            shared.append(
                channel: .ble,
                direction: .received,
                title: formatted.title,
                detail: formatted.detail
            )
        }
    }

    /// Callback evidence captured before framing, including headerless continuations
    /// and ATT errors. The connection owner applies its raw diagnostic budget.
    nonisolated static func logBLERawReceived(
        data: Data?,
        peripheralID: String,
        characteristicID: String,
        context: String,
        error: String? = nil,
        capturedAt: Date
    ) {
        let formatted = BLENotificationDiagnostics.format(
            data: data,
            peripheralID: peripheralID,
            characteristicID: characteristicID,
            context: context,
            error: error
        )
        Task { @MainActor in
            shared.append(
                channel: .ble,
                direction: .received,
                title: formatted.title,
                detail: formatted.detail,
                date: capturedAt
            )
        }
    }

    nonisolated static func logBLEEvent(
        _ title: String,
        detail: String = "",
        capturedAt: Date = Date()
    ) {
        Task { @MainActor in
            shared.append(
                channel: .ble,
                direction: .event,
                title: title,
                detail: detail,
                date: capturedAt
            )
        }
    }

    // MARK: - Connect lifecycle

    /// 自动连接 / 重连相关事件。`direction` 默认 `.event`；App 发起可用 `.sent`，系统回调可用 `.received`。
    nonisolated static func logConnect(
        _ title: String,
        detail: String = "",
        direction: Direction = .event
    ) {
        Task { @MainActor in
            shared.append(
                channel: .connect,
                direction: direction,
                title: title,
                detail: detail
            )
        }
    }

    // MARK: - Wi-Fi lifecycle

    /// 眼镜 Wi-Fi 配网诊断，包含用于比对设备与系统配置的热点口令。
    nonisolated static func logWiFi(
        _ title: String,
        detail: String = "",
        direction: Direction = .event
    ) {
        Task { @MainActor in
            shared.append(
                channel: .wifi,
                direction: direction,
                title: title,
                detail: detail
            )
        }
    }

    func clear(channel: Channel) {
        switch channel {
        case .http:
            httpEntries.removeAll()
        case .ble:
            bleEntries.removeAll()
        case .wifi:
            wifiEntries.removeAll()
        case .connect:
            connectEntries.removeAll()
        }
    }

    /// 当前频道全部日志拼成可分享文本。
    func exportText(for channel: Channel) -> String {
        let entries: [Entry]
        let channelName: String
        switch channel {
        case .http:
            entries = httpEntries
            channelName = "HTTP"
        case .ble:
            entries = bleEntries
            channelName = "蓝牙"
        case .wifi:
            entries = wifiEntries
            channelName = "Wi-Fi"
        case .connect:
            entries = connectEntries
            channelName = "连接"
        }

        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let lineFormatter = DateFormatter()
        lineFormatter.dateFormat = "HH:mm:ss.SSS"

        var lines: [String] = [
            "=== AIGlass \(channelName) 调试日志 ===",
            "App版本: \(AppBundleInfo.shortVersion) (\(AppBundleInfo.buildNumber))",
            "系统版本: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "导出时间: \(stampFormatter.string(from: Date()))",
            "条数: \(entries.count)",
            ""
        ]

        if entries.isEmpty {
            lines.append("(暂无记录)")
        } else {
            for entry in entries {
                lines.append("[\(lineFormatter.string(from: entry.date))] [\(entry.direction.label)] \(entry.title)")
                if !entry.detail.isEmpty {
                    lines.append(entry.detail)
                }
                lines.append("---")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 写入临时文件，供系统分享。文件名含频道与时间戳。
    func exportFileURL(for channel: Channel) throws -> URL {
        let channelKey: String
        switch channel {
        case .http: channelKey = "http"
        case .ble: channelKey = "ble"
        case .wifi: channelKey = "wifi"
        case .connect: channelKey = "connect"
        }
        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "aiglass_\(channelKey)_log_\(nameFormatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try exportText(for: channel).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Private

    private func append(channel: Channel, direction: Direction, title: String, detail: String, date: Date = Date()) {
        let entry = Entry(
            id: UUID(),
            date: date,
            channel: channel,
            direction: direction,
            title: title,
            detail: detail
        )
        switch channel {
        case .http:
            httpEntries.append(entry)
            trim(&httpEntries)
        case .ble:
            bleEntries.append(entry)
            trim(&bleEntries)
        case .wifi:
            wifiEntries.append(entry)
            trim(&wifiEntries)
        case .connect:
            connectEntries.append(entry)
            trim(&connectEntries)
        }
    }

    private func trim(_ entries: inout [Entry]) {
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    nonisolated private static func shortPath(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        let path = parsed.path.isEmpty ? "/" : parsed.path
        if let query = parsed.query, !query.isEmpty {
            return path + "?" + query
        }
        return path
    }

    nonisolated static func headerFields(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        }
    }

    nonisolated private static func composeHTTPDetail(
        url: String,
        headers: [String: String]?,
        body: String?,
        extra: String?
    ) -> String {
        var parts: [String] = [url]
        if let extra, !extra.isEmpty {
            parts.append(extra)
        }
        if let headerText = formatHTTPHeaders(headers) {
            parts.append("headers:\n\(headerText)")
        }
        if let body, !body.isEmpty {
            parts.append(truncate(body, limit: 4000))
        }
        return parts.joined(separator: "\n")
    }

    nonisolated private static func formatHTTPHeaders(_ headers: [String: String]?) -> String? {
        guard let headers, !headers.isEmpty else { return nil }
        let sensitiveNames: Set<String> = [
            "authorization",
            "proxy-authorization",
            "cookie",
            "set-cookie",
            "x-api-key",
            "api-key"
        ]
        return headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { key, value in
                sensitiveNames.contains(key.lowercased())
                    ? "\(key): <redacted>"
                    : "\(key): \(value)"
            }
            .joined(separator: "\n")
    }

    nonisolated private static func formatBLE(_ data: Data) -> (title: String, detail: String) {
        let command = AstraA1BleProtocol.parseCommandHeader(from: data) ?? "raw"
        let meaning = bleMeaning(command: command, data: data)
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let payloadLen: String
        if data.count >= 12 {
            let declared = Int(data[10]) | (Int(data[11]) << 8)
            payloadLen = "payload=\(declared)B actual=\(max(0, data.count - 12))B"
        } else {
            payloadLen = "len=\(data.count)B"
        }

        let title: String
        if meaning.isEmpty {
            title = command
        } else {
            title = "\(command) · \(meaning)"
        }

        var detailParts = [meaning.isEmpty ? commandMeaningFallback(command) : meaning]
        detailParts.append("cmd=\(command) \(payloadLen)")
        detailParts.append(truncate(hex, limit: 1200))
        return (title, detailParts.joined(separator: "\n"))
    }

    /// 尽量解析出和设备日志同风格的说明（如 `0 STANDBY 设备空闲`）。
    nonisolated private static func bleMeaning(command: String, data: Data) -> String {
        switch command {
        case "devstatus0":
            if let status = AstraA1BleProtocol.parseDevStatus(data) {
                return status.logDescription
            }
            return "设备状态上报（解析失败）"

        case "actionrsp0":
            if let response = AstraA1BleProtocol.parseActionResponse(data) {
                return "\(deviceActionLabel(response.action)) → \(deviceActionResultLabel(response.result)) (result=\(response.rawResult)) | 当前 \(response.currentStatus.logDescription)"
            }
            return "动作回执（解析失败）"

        case "getdevstat":
            return "查询设备运行状态"

        case "takephoto0":
            return "拍照"

        case "startvideo":
            return "开始录像"

        case "stopvideo0":
            return "停止录像"

        case "toopenwifi":
            if data.count >= 13 {
                let purpose = data[12]
                let purposeText: String
                switch purpose {
                case 0: purposeText = "导图"
                case 1: purposeText = "OTA"
                default: purposeText = "purpose=\(purpose)"
                }
                return "开启 Wi-Fi（\(purposeText)）"
            }
            return "开启 Wi-Fi"

        case "closewifi", "closewifi0":
            return "关闭 Wi-Fi"

        case "wificonfig":
            if let config = AstraA1BleProtocol.parseWifiConfig(data) {
                var parts: [String] = ["Wi-Fi 配置"]
                if let ssid = config.ssid, !ssid.isEmpty { parts.append("ssid=\(ssid)") }
                parts.append("passwordEmpty=\((config.password ?? "").isEmpty)")
                if let http = config.httpAddress, !http.isEmpty { parts.append("http=\(http)") }
                return parts.joined(separator: " ")
            }
            return "Wi-Fi 配置（解析失败）"

        case "getworkpat":
            if data.count >= 13 {
                switch data[12] {
                case 0x01: return "获取下载路径"
                case 0x02: return "获取 OTA 路径"
                case 0x03: return "获取上传路径"
                default: return "获取工作路径 type=\(data[12])"
                }
            }
            return "获取工作路径"

        case "hasnewfile":
            if let info = AstraA1BleProtocol.parseHasNewFileResponse(data) {
                return info.hasNew ? "有新文件 count=\(info.fileCount)" : "无新文件"
            }
            return data.count <= 12 ? "查询待导入文件" : "待导入文件（解析失败）"

        case "transferok":
            if data.count >= 13 {
                return data[12] == 0x01 ? "传输确认：成功" : "传输确认：失败"
            }
            return "传输确认"

        case "getdevinfo":
            if let info = AstraA1BleProtocol.parseGetDevInfoResponse(data) {
                return "设备信息 \(info.key)=\(info.value)"
            }
            return data.count <= 12 ? "查询设备信息" : "设备信息回执"

        case "otaprogres", "otaprogre":
            if let percent = AstraA1BleProtocol.parseOtaProgress(data) {
                return "OTA 进度 \(percent)%"
            }
            return "OTA 进度"

        case "otaupload0":
            return "启动蓝牙固件 OTA"

        case "otaupload1":
            return "启动主固件 OTA"
        case "getalgoinf":
            return "查询算法 DLL 信息"
        case "dllupload0":
            return "安装算法 DLL"
        case "dllprogres":
            if let percent = AstraA1BleProtocol.parseDLLProgress(data) {
                return "算法 DLL 安装进度 \(percent)%"
            }
            return "算法 DLL 安装进度"
        case "dllupdrsp0":
            if let result = AstraA1BleProtocol.parseDLLUpdateResult(data) {
                return "算法 DLL 安装结果 status=\(result.status) done=\(result.doneCount) failId=\(result.failID)"
            }
            return "算法 DLL 安装结果"

        case "deletefile":
            return "删除设备文件"

        case "imgrecset0":
            if data.count >= 13 {
                return "同步识图档位 level=\(data[12])"
            }
            return "同步识图档位"

        case "imgreccap0":
            if data.count >= 13 {
                return "触发识图拍照 level=\(data[12])"
            }
            return "触发识图拍照"

        case "imgreccan0":
            return "取消识图"

        case "imgrecrsp0":
            if let response = AstraA1BleProtocol.parseAIVisionResponse(data) {
                let op = response.op == 0 ? "set" : "capture"
                if response.isSuccess {
                    return "识图回执 \(op) 成功"
                }
                return "识图回执 \(op) 失败: \(response.errorMessage)"
            }
            return "识图回执"

        case "imgrecdata":
            if let packet = AstraA1BleProtocol.parseAIVisionDataPacket(data) {
                return "识图图片包 \(packet.seq)/\(packet.total)"
            }
            return "识图图片包"

        default:
            return commandMeaningFallback(command)
        }
    }

    nonisolated private static func commandMeaningFallback(_ command: String) -> String {
        switch command {
        case "raw": return "原始数据"
        default: return "指令 \(command)"
        }
    }

    nonisolated private static func deviceActionLabel(
        _ action: AstraA1BleProtocol.DeviceAction
    ) -> String {
        switch action {
        case .takePhoto: return "拍照"
        case .startVideo: return "开始录像"
        case .stopVideo: return "停止录像"
        case .startVoiceRecord: return "开始录音"
        case .stopVoiceRecord: return "停止录音"
        case .startFileImport: return "开始导图"
        case .startAIVision: return "开始识图"
        case .startFirmwareUpgrade: return "开始升级"
        case .cancelFirmwareUpgrade: return "取消升级"
        }
    }

    nonisolated private static func deviceActionResultLabel(
        _ result: AstraA1BleProtocol.DeviceActionResult
    ) -> String {
        switch result {
        case .accepted: return "接受"
        case .busy: return "忙碌拒绝"
        case .invalidState: return "状态非法"
        case .failed: return "失败"
        }
    }

    nonisolated private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…(\(text.count) chars)"
    }

    nonisolated static func utf8Body(from data: Data?, binaryHint: String? = nil) -> String? {
        guard let data else { return binaryHint }
        if data.isEmpty { return binaryHint ?? "(empty)" }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        if let hint = binaryHint {
            return hint
        }
        return "<binary \(data.count) bytes>"
    }

    nonisolated static func jsonBody(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text
    }
}
