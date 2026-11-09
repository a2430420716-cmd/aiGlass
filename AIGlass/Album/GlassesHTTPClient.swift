import Foundation
import Network

/// 眼镜芯片自带的极简 HTTP 服务器（"Index of /"）在返回文件时，
/// Content-Length 头可能缺失/错误，body 依赖「连接关闭」终止。
/// URLSession 会按 Content-Length 提前结束而返回 0 字节，因此改用原始 TCP：
/// 手写 HTTP/1.1 请求，读到连接关闭为止（等价 Android 的 read-until-EOF），
/// 并强制绑定 Wi-Fi 接口，避免请求被路由到蜂窝网络。
enum GlassesHTTPClient {
    private static let logTag = "[GlassesHTTP]"

    static func fetchText(baseURL: String, path: String = "") async throws -> String {
        let (status, _, body) = try await rawGet(baseURL: baseURL, path: path, timeout: 20)
        // 眼镜目录页要求尾斜杠；无斜杠常回 301 / "Error: 301"。
        if (300...399).contains(status) || isDirectoryRedirectBody(body) {
            let slashURL = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
            // 列表请求：强制再试一次带尾斜杠的目录 URL。
            if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let (retryStatus, _, retryBody) = try await rawGet(
                    baseURL: slashURL,
                    path: "",
                    timeout: 20
                )
                guard (200...299).contains(retryStatus) || retryStatus == 0 else {
                    throw GlassesHTTPError.httpStatus(retryStatus == 0 ? 301 : retryStatus)
                }
                let retryText = decodeTextBody(retryBody)
                if isDirectoryRedirectBody(retryBody) {
                    throw GlassesHTTPError.httpStatus(301)
                }
                return retryText
            }
            throw GlassesHTTPError.httpStatus(status == 0 ? 301 : status)
        }
        guard (200...299).contains(status) || status == 0 else {
            throw GlassesHTTPError.httpStatus(status)
        }
        let text = decodeTextBody(body)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Error:") {
            throw GlassesHTTPError.requestFailed(text)
        }
        return text
    }

    private static func decodeTextBody(_ body: Data) -> String {
        if let utf8 = String(data: body, encoding: .utf8), !utf8.isEmpty { return utf8 }
        if let latin = String(data: body, encoding: .isoLatin1), !latin.isEmpty { return latin }
        return String(decoding: body, as: UTF8.self)
    }

    private static func isDirectoryRedirectBody(_ body: Data) -> Bool {
        let text = decodeTextBody(body).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text == "error: 301" || text.hasPrefix("error: 301")
    }

    static func fetchData(
        baseURL: String, fileName: String, timeout: TimeInterval = 120,
        connectTimeout: TimeInterval = 10
    ) async throws -> Data {
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let (status, headerText, body) = try await rawGet(
            baseURL: baseURL, path: encoded, timeout: timeout, connectTimeout: connectTimeout
        )
        print("\(logTag) download \(fileName) status=\(status) bytes=\(body.count)")
        print("\(logTag) ---- response headers ----\n\(headerText)\n\(logTag) --------------------------")
        guard (200...299).contains(status) else {
            throw GlassesHTTPError.httpStatus(status)
        }
        guard !body.isEmpty else {
            throw GlassesHTTPError.emptyBody
        }
        return body
    }

    /// HTTP PUT 上传固件到眼镜 OTA 路径（文档 7.2 Step 4）。
    static func uploadFirmware(
        otaBaseURL: String,
        fileName: String,
        body: Data,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws {
        guard let base = URL(string: otaBaseURL), let host = base.host else {
            throw GlassesHTTPError.invalidURL
        }
        let port = UInt16(base.port ?? 80)
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        var path = base.path
        if path.isEmpty { path = "/fw_upload" }
        if !path.hasSuffix("/") { path += "/" }
        path += encoded

        let urlText = "http://\(host):\(port)\(path)"
        DebugLogStore.logHTTPSent(
            method: "PUT",
            url: urlText,
            body: "firmware=\(fileName) bytes=\(body.count)",
            headers: [
                "Host": host,
                "User-Agent": "AIGlass/1.0",
                "Content-Type": "application/octet-stream",
                "Content-Length": String(body.count),
                "Connection": "close"
            ]
        )

        let response: GlassesHTTPUploadResponse.Outcome
        do {
            response = try await RawHTTPConnection.put(
                host: host,
                port: port,
                path: path,
                body: body,
                timeout: max(60, TimeInterval(body.count / (100 * 1024)) + 30),
                onProgress: onProgress
            )
        } catch {
            DebugLogStore.logHTTPReceived(
                method: "PUT",
                url: urlText,
                statusCode: nil,
                body: nil,
                error: error.localizedDescription
            )
            throw error
        }
        let status = response.statusCode
        print("\(logTag) upload \(fileName) status=\(status.map(String.init) ?? "unverified") bytes=\(body.count)")
        DebugLogStore.logHTTPReceived(
            method: "PUT",
            url: urlText,
            statusCode: status,
            body: status == nil ? "Android-compatible continuation after complete local send; HTTPResponseVerified=false; device result still required" : nil
        )
        if let status, !(200...299).contains(status) {
            throw GlassesHTTPError.httpStatus(status)
        }
    }

    // MARK: - Raw HTTP over TCP

    private static func rawGet(
        baseURL: String, path: String, timeout: TimeInterval, connectTimeout: TimeInterval = 10
    ) async throws -> (status: Int, headerText: String, body: Data) {
        guard let url = URL(string: baseURL), let host = url.host else {
            throw GlassesHTTPError.invalidURL
        }
        let port = UInt16(url.port ?? 80)
        // 必须保留 baseURL 的 path（如 /airecord/）；URL.path 会吃掉尾斜杠。
        let requestPath = resolveRequestPath(baseURLString: baseURL, baseURL: url, path: path)

        print("\(logTag) raw GET http://\(host):\(port)\(requestPath)")
        let urlText = "http://\(host):\(port)\(requestPath)"
        DebugLogStore.logHTTPSent(
            method: "GET",
            url: urlText,
            body: nil,
            headers: [
                "Host": host,
                "User-Agent": "AIGlass/1.0",
                "Accept": "*/*",
                "Connection": "close"
            ]
        )

        let raw: Data
        do {
            raw = try await RawHTTPConnection.get(
                host: host,
                port: port,
                path: requestPath,
                timeout: timeout,
                connectTimeout: connectTimeout
            )
        } catch {
            DebugLogStore.logHTTPReceived(
                method: "GET",
                url: urlText,
                statusCode: nil,
                body: nil,
                error: error.localizedDescription
            )
            throw error
        }
        print("\(logTag) raw total received=\(raw.count) bytes")
        do {
            let parsed = try parseHTTPResponse(raw)
            let bodyPreview: String?
            if parsed.body.count > 2048 {
                bodyPreview = "<binary/text \(parsed.body.count) bytes>\n\(parsed.headerText)"
            } else {
                bodyPreview = DebugLogStore.utf8Body(
                    from: parsed.body,
                    binaryHint: "<body \(parsed.body.count) bytes>\n\(parsed.headerText)"
                )
            }
            DebugLogStore.logHTTPReceived(
                method: "GET",
                url: urlText,
                statusCode: parsed.status,
                body: bodyPreview,
                headers: parseHeaderFields(parsed.headerText)
            )
            return parsed
        } catch {
            DebugLogStore.logHTTPReceived(
                method: "GET",
                url: urlText,
                statusCode: nil,
                body: "<raw \(raw.count) bytes>",
                error: error.localizedDescription
            )
            throw error
        }
    }

    private static func parseHeaderFields(_ headerText: String) -> [String: String] {
        headerText
            .components(separatedBy: "\r\n")
            .dropFirst()
            .reduce(into: [String: String]()) { result, line in
                guard let separator = line.firstIndex(of: ":") else { return }
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return }
                if let existing = result[key], !existing.isEmpty {
                    result[key] = existing + ", " + value
                } else {
                    result[key] = value
                }
            }
    }

    /// 将 baseURL.path 与相对 path 拼成最终请求路径。
    /// - `http://192.168.0.1/` + `` → `/`
    /// - `http://192.168.0.1/airecord/` + `` → `/airecord/`（必须带尾斜杠，否则设备 301）
    /// - `http://192.168.0.1/airecord/` + `a.aac` → `/airecord/a.aac`
    private static func resolveRequestPath(baseURLString: String, baseURL: URL, path: String) -> String {
        var basePath = baseURL.path
        if basePath.isEmpty { basePath = "/" }
        // Foundation URL.path 常去掉尾斜杠；目录列表必须保留。
        if baseURLString.hasSuffix("/") && !basePath.hasSuffix("/") {
            basePath += "/"
        }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // 列目录：无扩展名的路径统一补尾斜杠（避免 /airecord → 301）
            if basePath != "/", !basePath.hasSuffix("/"), !basePath.contains(".") {
                basePath += "/"
            }
            return basePath
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"),
           let absolute = URL(string: trimmed) {
            var absolutePath = absolute.path
            if absolutePath.isEmpty { absolutePath = "/" }
            if trimmed.hasSuffix("/") && !absolutePath.hasSuffix("/") {
                absolutePath += "/"
            }
            return absolutePath
        }
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        if !basePath.hasSuffix("/") {
            basePath += "/"
        }
        return basePath + trimmed
    }

    private static func parseHTTPResponse(_ data: Data) throws -> (status: Int, headerText: String, body: Data) {
        // 找到 header/body 分隔 \r\n\r\n
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = data.range(of: separator) else {
            // 没有标准分隔，退而求其次：整体当 body
            throw GlassesHTTPError.badResponse
        }
        let headerData = data.subdata(in: data.startIndex..<range.lowerBound)
        var body = data.subdata(in: range.upperBound..<data.endIndex)

        let headerText = String(data: headerData, encoding: .isoLatin1) ?? ""
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw GlassesHTTPError.badResponse
        }
        // "HTTP/1.1 200 OK"
        let parts = statusLine.split(separator: " ")
        let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0

        // 解析是否 chunked
        let isChunked = lines.contains { line in
            line.lowercased().hasPrefix("transfer-encoding:") && line.lowercased().contains("chunked")
        }
        if isChunked {
            body = decodeChunked(body)
        }

        return (status, headerText, body)
    }

    /// 解码 chunked transfer-encoding。
    private static func decodeChunked(_ data: Data) -> Data {
        var result = Data()
        var index = data.startIndex
        let crlf = Data([0x0D, 0x0A])

        while index < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { break }
            let sizeLine = data.subdata(in: index..<lineEnd.lowerBound)
            let sizeStr = String(data: sizeLine, encoding: .isoLatin1)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            // chunk size 可能带扩展（; 后），只取前面部分
            let hexPart = sizeStr.split(separator: ";").first.map(String.init) ?? sizeStr
            guard let chunkSize = Int(hexPart, radix: 16) else { break }
            if chunkSize == 0 { break }

            let chunkStart = lineEnd.upperBound
            let chunkEnd = data.index(chunkStart, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            result.append(data.subdata(in: chunkStart..<chunkEnd))

            // 跳过 chunk 后的 \r\n
            index = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return result
    }
}

/// A task can be cancelled from any executor; transport state remains on its serial queue.
nonisolated private final class HTTPTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (@Sendable () -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        self.action = action
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { action() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = action
        lock.unlock()
        action?()
    }

    func complete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        action = nil
        return cancelled
    }
}

/// One HTTP request per Wi-Fi-only connection. Association and HTTP have separate deadlines.
nonisolated private enum RawHTTPConnection {
    /// Accessed exclusively on each request's serial queue.
    private final class RequestState: @unchecked Sendable {
        var finished = false
        var requestStarted = false
        var bodySendCompleted = false
        var received = Data()
        var response = GlassesHTTPUploadResponse()
    }
    // Android HttpURLConnection uses a 10-second connect timeout and a 30-second PUT read timeout.
    private static let connectTimeout: TimeInterval = 10
    private static let uploadResponseTimeout: TimeInterval = 30

    private static func makeConnection(host: String, port: UInt16) -> NWConnection {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        parameters.prohibitedInterfaceTypes = [.cellular]
        return NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 80, using: parameters)
    }

    /// Record the real HTTP connection now that a separate TCP probe no longer gates hotspot joining.
    private static func logConnection(
        _ connection: NWConnection, id: String, method: String, host: String, port: UInt16,
        path: String, event: String, detail: String = "", error: NWError? = nil
    ) {
        let interfaces = WifiDiagnosticSession.captureInterfaces()
        DebugLogStore.logWiFi(
            "眼镜 HTTP \(method) \(event)",
            detail: "httpDiagnosticVersion=4 requestID=\(id) uptime=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))s\nhost=\(host) port=\(port) path=\(path)\nconnectionState=\(connection.state)\nrequiredInterfaceType=wifi prohibitedInterfaceTypes=cellular\nselectedIPv4=\(interfaces.selectedIPv4 ?? "none")\n\(WifiConnectionDiagnostics.interfaceDescription(interfaces))\n\(TCPReachability.pathDescription(connection.currentPath))\n\(error.map { TCPReachability.errorDescription($0) } ?? "")\n\(detail)",
            direction: .received
        )
    }

    static func get(
        host: String, port: UInt16, path: String, timeout: TimeInterval,
        connectTimeout: TimeInterval
    ) async throws -> Data {
        let cancellation = HTTPTaskCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let queue = DispatchQueue(label: "com.aiglass.rawhttp")
                let connection = makeConnection(host: host, port: port)
                let id = UUID().uuidString
                let requestState = RequestState()
                let request = "GET \(path) HTTP/1.1\r\n"
                    + "Host: \(host)\r\nUser-Agent: AIGlass/1.0\r\nAccept: */*\r\nConnection: close\r\n\r\n"

                let log: @Sendable (String, String, NWError?) -> Void = { event, detail, error in
                    logConnection(connection, id: id, method: "GET", host: host, port: port, path: path,
                                  event: event, detail: "receivedBytes=\(requestState.received.count) requestStarted=\(requestState.requestStarted)\n\(detail)", error: error)
                }
                // All callers run on queue. Finish synchronously so competing callbacks cannot win twice.
                let finish: @Sendable (Result<Data, Error>) -> Void = { result in
                    guard !requestState.finished else { return }
                    requestState.finished = true
                    // Delayed deadline closures may live for the full transfer budget.
                    // The result owns its Data; do not retain another file buffer here.
                    requestState.received = Data()
                    let cancelled = cancellation.complete()
                    connection.stateUpdateHandler = nil
                    connection.pathUpdateHandler = nil
                    connection.viabilityUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(with: cancelled ? .failure(CancellationError()) : result)
                }
                @Sendable func receiveLoop() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                        guard !requestState.finished else { return }
                        if let data { requestState.received.append(data) }
                        if let error {
                            log("连接中断", "", error)
                            finish(.failure(GlassesHTTPError.unreachable))
                        } else if isComplete {
                            finish(.success(requestState.received))
                        } else {
                            receiveLoop()
                        }
                    }
                }

                connection.stateUpdateHandler = { state in
                    guard !requestState.finished else { return }
                    switch state {
                    case .ready:
                        log("Wi-Fi 路由就绪", "", nil)
                        // A waiting -> ready transition must never replay an HTTP request.
                        guard !requestState.requestStarted else { return }
                        requestState.requestStarted = true
                        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                            guard !requestState.finished else { return }
                            if let error {
                                log("发送失败", "", error)
                                finish(.failure(GlassesHTTPError.unreachable))
                            } else {
                                receiveLoop()
                            }
                        })
                    case .waiting(let error):
                        log("等待网络", "connectTimeout=\(connectTimeout)s overallTimeout=\(timeout)s; keep_waiting_within_deadline", error)
                    case .failed(let error):
                        log("连接失败", "", error)
                        finish(.failure(GlassesHTTPError.unreachable))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.pathUpdateHandler = { _ in
                    guard !requestState.finished else { return }
                    log("路径变化", "", nil)
                }
                connection.viabilityUpdateHandler = { viable in
                    guard !requestState.finished else { return }
                    log("连接可用性变化", "isViable=\(viable)", nil)
                }
                cancellation.install {
                    queue.async {
                        guard !requestState.finished else { return }
                        log("已取消", "", nil)
                        finish(.failure(CancellationError()))
                    }
                }
                queue.async {
                    guard !requestState.finished else { return }
                    guard !cancellation.isCancelled else {
                        finish(.failure(CancellationError()))
                        return
                    }
                    log("开始连接", "connectTimeout=\(connectTimeout)s overallTimeout=\(timeout)s", nil)
                    queue.asyncAfter(deadline: .now() + connectTimeout) {
                        guard !requestState.finished, !requestState.requestStarted else { return }
                        log("连接超时", "failureBoundary=TCP-connect", nil)
                        finish(.failure(GlassesHTTPError.unreachable))
                    }
                    queue.asyncAfter(deadline: .now() + timeout) {
                        guard !requestState.finished else { return }
                        log("请求超时", "timeout=\(timeout)s", nil)
                        // Preserve the existing EOF-less GET behavior; callers still validate file size.
                        finish(requestState.received.isEmpty ? .failure(GlassesHTTPError.unreachable) : .success(requestState.received))
                    }
                    connection.start(queue: queue)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func put(
        host: String, port: UInt16, path: String, body: Data, timeout: TimeInterval,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> GlassesHTTPUploadResponse.Outcome {
        let requestPath = path.hasPrefix("/") ? path : "/" + path
        let cancellation = HTTPTaskCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GlassesHTTPUploadResponse.Outcome, Error>) in
                let queue = DispatchQueue(label: "com.aiglass.rawhttp.put")
                let connection = makeConnection(host: host, port: port)
                let id = UUID().uuidString
                let totalBytes = body.count
                let requestState = RequestState()

                let log: @Sendable (String, String, NWError?) -> Void = { event, detail, error in
                    logConnection(connection, id: id, method: "PUT", host: host, port: port, path: requestPath,
                                  event: event, detail: "bytes=\(totalBytes) requestStarted=\(requestState.requestStarted) bodySendCompleted=\(requestState.bodySendCompleted)\n\(detail)", error: error)
                }
                let finish: @Sendable (Result<GlassesHTTPUploadResponse.Outcome, Error>) -> Void = { result in
                    guard !requestState.finished else { return }
                    requestState.finished = true
                    let cancelled = cancellation.complete()
                    connection.stateUpdateHandler = nil
                    connection.pathUpdateHandler = nil
                    connection.viabilityUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(with: cancelled ? .failure(CancellationError()) : result)
                }
                @Sendable func receiveResponse() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                        guard !requestState.finished else { return }
                        // Data and an error can arrive together. An observed HTTP rejection always wins.
                        switch requestState.response.append(data ?? Data()) {
                        case .status(let code):
                            log("收到响应", "status=\(code) HTTPResponseVerified=true", error)
                            finish(.success(.httpStatus(code)))
                            return
                        case .invalid:
                            log("响应格式异常", "", error)
                            finish(.failure(GlassesHTTPError.badResponse))
                            return
                        case .pending:
                            break
                        }
                        if let error {
                            if let outcome = requestState.response.outcomeAfterConnectionError(
                                error, bodySendCompleted: requestState.bodySendCompleted, totalBytes: totalBytes,
                                cancelled: cancellation.isCancelled
                            ) {
                                log("完整发送后连接关闭，按安卓兼容继续",
                                    "HTTPResponseVerified=false deviceAcceptanceVerified=false continuationReason=connectionClosedAfterCompleteLocalSend; awaiting_device_result", error)
                                finish(.success(outcome))
                            } else {
                                log("连接中断", "HTTPResponseVerified=false", error)
                                finish(.failure(GlassesHTTPError.unreachable))
                            }
                        } else if isComplete {
                            // A clean EOF with no status is not Android's reset exception compatibility path.
                            log("响应提前结束", "HTTPResponseVerified=false", nil)
                            finish(.failure(GlassesHTTPError.badResponse))
                        } else {
                            receiveResponse()
                        }
                    }
                }

                connection.stateUpdateHandler = { state in
                    guard !requestState.finished else { return }
                    switch state {
                    case .ready:
                        log("Wi-Fi 路由就绪", "", nil)
                        guard !requestState.requestStarted else { return }
                        requestState.requestStarted = true
                        let headers = "PUT \(requestPath) HTTP/1.1\r\n"
                            + "Host: \(host)\r\nUser-Agent: AIGlass/1.0\r\nContent-Type: application/octet-stream\r\n"
                            + "Content-Length: \(totalBytes)\r\nConnection: close\r\n\r\n"
                        var payload = Data(headers.utf8)
                        payload.append(body)
                        connection.send(content: payload, completion: .contentProcessed { error in
                            guard !requestState.finished else { return }
                            if let error {
                                log("发送失败", "HTTPResponseVerified=false", error)
                                finish(.failure(GlassesHTTPError.unreachable))
                                return
                            }
                            requestState.bodySendCompleted = true
                            log("本地发送完成，等待响应", "responseTimeout=\(uploadResponseTimeout)s HTTPResponseVerified=false deviceAcceptanceVerified=false", nil)
                            onProgress?(100)
                            queue.asyncAfter(deadline: .now() + uploadResponseTimeout) {
                                guard !requestState.finished else { return }
                                log("响应超时", "failureBoundary=HTTP-response HTTPResponseVerified=false", nil)
                                finish(.failure(GlassesHTTPError.unreachable))
                            }
                            receiveResponse()
                        })
                    case .waiting(let error):
                        log("等待网络", "connectTimeout=\(connectTimeout)s overallTimeout=\(timeout)s; keep_waiting_within_deadline", error)
                    case .failed(let error):
                        log("连接失败", "", error)
                        // Once sending starts, its completion or pending receive owns the outcome.
                        // Finishing here could mask a HTTP 500 carried by the receive callback.
                        if !requestState.requestStarted { finish(.failure(GlassesHTTPError.unreachable)) }
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.pathUpdateHandler = { _ in
                    guard !requestState.finished else { return }
                    log("路径变化", "", nil)
                }
                connection.viabilityUpdateHandler = { viable in
                    guard !requestState.finished else { return }
                    log("连接可用性变化", "isViable=\(viable)", nil)
                }
                cancellation.install {
                    queue.async {
                        guard !requestState.finished else { return }
                        log("已取消", "", nil)
                        finish(.failure(CancellationError()))
                    }
                }
                queue.async {
                    guard !requestState.finished else { return }
                    guard !cancellation.isCancelled else {
                        finish(.failure(CancellationError()))
                        return
                    }
                    log("开始连接", "connectTimeout=\(connectTimeout)s responseTimeout=\(uploadResponseTimeout)s overallTimeout=\(timeout)s", nil)
                    queue.asyncAfter(deadline: .now() + connectTimeout) {
                        guard !requestState.finished, !requestState.requestStarted else { return }
                        log("连接超时", "failureBoundary=TCP-connect", nil)
                        finish(.failure(GlassesHTTPError.unreachable))
                    }
                    queue.asyncAfter(deadline: .now() + timeout) {
                        guard !requestState.finished else { return }
                        log("请求超时", "failureBoundary=overall-request HTTPResponseVerified=false", nil)
                        finish(.failure(GlassesHTTPError.unreachable))
                    }
                    connection.start(queue: queue)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// 仅建立 TCP 连接探测端口可达性；成功不代表 HTTP 协议或 OTA 上传正常。
nonisolated enum TCPReachability {
    /// Mutable state is accessed only from the probe's serial queue.
    nonisolated private final class CompletionState: @unchecked Sendable {
        var finished = false
        var lastConnectionState = "notObserved"
        var lastConnectionStateAt: TimeInterval?
        var lastWaitingError: NWError?
        var lastWaitingErrorAt: TimeInterval?
        var lastPathDescription: String?
        var lastViability: Bool?
    }

    static func canConnect(
        host: String,
        port: UInt16,
        timeout: TimeInterval,
        diagnosticID: String? = nil,
        probeAttempt: Int? = nil
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let queue = DispatchQueue(label: "com.aiglass.tcpprobe")
            let startedAt = ProcessInfo.processInfo.systemUptime
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            parameters.prohibitedInterfaceTypes = [.cellular]

            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 80,
                using: parameters
            )
            let completionState = CompletionState()
            let logState: (String, String, NWError?) -> Void = { title, state, error in
                let uptime = ProcessInfo.processInfo.systemUptime
                var detail = [
                    "tcpDiagnosticVersion=2",
                    "diagnosticID=\(diagnosticID ?? "unavailable")",
                    "probeAttempt=\(probeAttempt.map(String.init) ?? "unavailable")",
                    "uptime=\(String(format: "%.3f", uptime))s",
                    "elapsed=\(String(format: "%.3f", uptime - startedAt))s",
                    "host=\(host)",
                    "port=\(port)",
                    "timeout=\(String(format: "%.1f", timeout))s",
                    "state=\(state)",
                    "lastConnectionState=\(completionState.lastConnectionState)",
                    "lastConnectionStateDuration=\(completionState.lastConnectionStateAt.map { String(format: "%.3f", uptime - $0) + "s" } ?? "unavailable")",
                    "lastReportedViability=\(completionState.lastViability.map(String.init) ?? "unavailable")",
                    "requiredInterfaceType=wifi",
                    "prohibitedInterfaceTypes=cellular",
                    pathDescription(connection.currentPath)
                ]
                if let error {
                    detail.append(errorDescription(error))
                }
                if let lastWaitingError = completionState.lastWaitingError {
                    detail.append(errorDescription(lastWaitingError, prefix: "lastWaitingError"))
                    detail.append("lastWaitingErrorAge=\(completionState.lastWaitingErrorAt.map { String(format: "%.3f", uptime - $0) + "s" } ?? "unavailable")")
                    detail.append("lastWaitingErrorIsHistorical=true")
                } else {
                    detail.append("lastWaitingError=noneObserved")
                }
                if let lastPathDescription = completionState.lastPathDescription {
                    detail.append(lastPathDescription)
                }
                if state == "ready" {
                    detail.append("result=TCP 连接成功；未发送 HTTP 请求，不证明 HTTP 协议或 OTA 上传正常")
                }
                DebugLogStore.logWiFi(title, detail: detail.joined(separator: "\n"), direction: .received)
            }
            // State callbacks and the deadline run on this serial queue. Finish synchronously
            // so a ready/failed callback cannot be followed by a misleading timeout log.
            let finish: (Bool) -> Void = { reachable in
                guard !completionState.finished else { return }
                completionState.finished = true
                connection.stateUpdateHandler = nil
                connection.pathUpdateHandler = nil
                connection.viabilityUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: reachable)
            }

            connection.stateUpdateHandler = { state in
                guard !completionState.finished else { return }
                let stateName = connectionStateName(state)
                if completionState.lastConnectionState != stateName {
                    completionState.lastConnectionState = stateName
                    completionState.lastConnectionStateAt = ProcessInfo.processInfo.systemUptime
                }
                switch state {
                case .setup:
                    logState("TCP 探测初始化", "setup", nil)
                case .preparing:
                    logState("TCP 探测正在建立连接", "preparing", nil)
                case .ready:
                    logState("TCP 探测端口可达", "ready", nil)
                    finish(true)
                case .waiting(let error):
                    completionState.lastWaitingError = error
                    completionState.lastWaitingErrorAt = ProcessInfo.processInfo.systemUptime
                    logState("TCP 探测等待网络", "waiting", error)
                case .failed(let error):
                    logState("TCP 探测连接失败", "failed", error)
                    finish(false)
                case .cancelled:
                    logState("TCP 探测已取消", "cancelled", nil)
                    finish(false)
                @unknown default:
                    logState("TCP 探测未知状态", String(describing: state), nil)
                }
            }
            connection.pathUpdateHandler = { path in
                guard !completionState.finished else { return }
                let description = pathDescription(path, prefix: "lastPathUpdate")
                guard description != completionState.lastPathDescription else { return }
                completionState.lastPathDescription = description
                logState("TCP 探测连接路径变化", "pathChanged", nil)
            }
            connection.viabilityUpdateHandler = { isViable in
                guard !completionState.finished,
                      completionState.lastViability != isViable else { return }
                completionState.lastViability = isViable
                logState("TCP 探测连接可用性变化", "viabilityChanged", nil)
            }
            queue.async {
                logState("TCP 探测开始", "started", nil)
                queue.asyncAfter(deadline: .now() + timeout) {
                    guard !completionState.finished else { return }
                    logState("TCP 探测超时", "timeout", nil)
                    finish(false)
                }
                connection.start(queue: queue)
            }
        }
    }

    private static func connectionStateName(_ state: NWConnection.State) -> String {
        switch state {
        case .setup: return "setup"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .waiting: return "waiting"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return String(describing: state)
        }
    }

    fileprivate static func errorDescription(_ error: NWError, prefix: String = "NWError") -> String {
        let nsError = error as NSError
        let errorCase: String
        let rawCode: String
        switch error {
        case .posix(let code):
            errorCase = "posix"
            rawCode = String(code.rawValue)
        case .dns(let code):
            errorCase = "dns"
            rawCode = String(code)
        case .tls(let code):
            errorCase = "tls"
            rawCode = String(code)
        default:
            errorCase = "unknown"
            rawCode = "unavailable"
        }
        return [
            "\(prefix).case=\(errorCase)",
            "\(prefix).domain=\(nsError.domain)",
            "\(prefix).code=\(nsError.code)",
            "\(prefix).rawCode=\(rawCode)",
            "\(prefix).description=\(String(describing: error))",
            "\(prefix).localizedDescription=\(error.localizedDescription)"
        ].joined(separator: "\n")
    }

    fileprivate static func pathDescription(_ path: NWPath?, prefix: String = "currentPath") -> String {
        guard let path else { return "\(prefix)=unavailable" }
        let interfaces = path.availableInterfaces.map { interface in
            "\(interface.name)(\(String(describing: interface.type)))"
        }.sorted().joined(separator: ",")
        return [
            "\(prefix).status=\(String(describing: path.status))",
            "\(prefix).unsatisfiedReason=\(path.status == .unsatisfied ? String(describing: path.unsatisfiedReason) : "notApplicable")",
            "\(prefix).supportsIPv4=\(path.supportsIPv4)",
            "\(prefix).supportsIPv6=\(path.supportsIPv6)",
            "\(prefix).usesWiFi=\(path.usesInterfaceType(.wifi))",
            "\(prefix).usesCellular=\(path.usesInterfaceType(.cellular))",
            "\(prefix).availableInterfaces=\(interfaces.isEmpty ? "none" : interfaces)"
        ].joined(separator: "\n")
    }
}

enum GlassesHTTPError: LocalizedError {
    case invalidURL
    case badResponse
    case httpStatus(Int)
    case emptyBody
    case sizeMismatch(expected: Int, actual: Int)
    case unreachable
    case requestFailed(String)

    var isConnectivityFailure: Bool {
        if case .unreachable = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L10n.t("无效的下载地址", "Invalid download URL")
        case .badResponse:
            return L10n.t("服务器响应异常", "Unexpected server response")
        case .httpStatus(let code):
            return L10n.t("HTTP 请求失败(\(code))", "HTTP request failed (\(code))")
        case .emptyBody:
            return L10n.t("文件为空", "File is empty")
        case .sizeMismatch(let expected, let actual):
            return L10n.t(
                "文件校验失败（期望 \(expected) 字节，实际 \(actual) 字节）",
                "File size mismatch (expected \(expected) bytes, got \(actual))"
            )
        case .unreachable:
            return L10n.t("无法访问眼镜文件服务，请确认已加入热点", "Cannot reach glasses file service. Confirm you joined the hotspot")
        case .requestFailed(let detail):
            return L10n.t("网络请求失败：\(detail)", "Network request failed: \(detail)")
        }
    }
}
