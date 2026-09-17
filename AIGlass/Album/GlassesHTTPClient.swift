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

    static func fetchData(baseURL: String, fileName: String) async throws -> Data {
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let (status, headerText, body) = try await rawGet(baseURL: baseURL, path: encoded, timeout: 120)
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

        let status: Int
        do {
            status = try await RawHTTPConnection.put(
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
        print("\(logTag) upload \(fileName) status=\(status) bytes=\(body.count)")
        DebugLogStore.logHTTPReceived(
            method: "PUT",
            url: urlText,
            statusCode: status,
            body: nil
        )
        guard (200...299).contains(status) else {
            throw GlassesHTTPError.httpStatus(status)
        }
    }

    // MARK: - Raw HTTP over TCP

    private static func rawGet(baseURL: String, path: String, timeout: TimeInterval) async throws -> (status: Int, headerText: String, body: Data) {
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
                timeout: timeout
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

/// 基于 NWConnection 的一次性 HTTP GET，读到连接关闭为止。
private enum RawHTTPConnection {
    /// 对齐 Android `onUnavailable`：短暂网络等待先给 2 秒恢复窗口，不能把一次
    /// `NWConnection.waiting` 直接当成热点已断开。
    private static let wifiWaitingGrace: TimeInterval = 2

    static func get(host: String, port: UInt16, path: String, timeout: TimeInterval) async throws -> Data {
        let parameters = NWParameters.tcp
        // 强制走 Wi-Fi，禁止蜂窝，确保连到眼镜热点的 192.168.0.1
        parameters.requiredInterfaceType = .wifi
        parameters.prohibitedInterfaceTypes = [.cellular]

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 80
        let connection = NWConnection(host: nwHost, port: nwPort, using: parameters)

        let request = "GET \(path) HTTP/1.1\r\n"
            + "Host: \(host)\r\n"
            + "User-Agent: AIGlass/1.0\r\n"
            + "Accept: */*\r\n"
            + "Connection: close\r\n"
            + "\r\n"

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let queue = DispatchQueue(label: "com.aiglass.rawhttp")
            var received = Data()
            var finished = false
            var requestStarted = false
            var waitingGeneration = 0

            let finish: (Result<Data, Error>) -> Void = { result in
                queue.async {
                    guard !finished else { return }
                    finished = true
                    connection.cancel()
                    continuation.resume(with: result)
                }
            }

            // 超时保护
            queue.asyncAfter(deadline: .now() + timeout) {
                if !finished {
                    if received.isEmpty {
                        DebugLogStore.logWiFi(
                            "眼镜 HTTP GET 超时",
                            detail: "host=\(host)\nport=\(port)\npath=\(path)\ntimeout=\(String(format: "%.1f", timeout))s\nreceivedBytes=0",
                            direction: .received
                        )
                        finish(.failure(GlassesHTTPError.unreachable))
                    } else {
                        DebugLogStore.logWiFi(
                            "眼镜 HTTP GET 等待结束超时，保留已收数据",
                            detail: "host=\(host)\nport=\(port)\npath=\(path)\ntimeout=\(String(format: "%.1f", timeout))s\nreceivedBytes=\(received.count)",
                            direction: .received
                        )
                        finish(.success(received))
                    }
                }
            }

            func receiveLoop() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        received.append(data)
                    }
                    if let error {
                        print("[GlassesHTTP] GET connection lost: \(error.localizedDescription)")
                        DebugLogStore.logWiFi(
                            "眼镜 HTTP GET 连接中断",
                            detail: "host=\(host)\nport=\(port)\npath=\(path)\nreceivedBytes=\(received.count)\nerror=\(error.localizedDescription)",
                            direction: .received
                        )
                        finish(.failure(GlassesHTTPError.unreachable))
                        return
                    }
                    if isComplete {
                        finish(.success(received))
                        return
                    }
                    receiveLoop()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    waitingGeneration += 1
                    DebugLogStore.logWiFi(
                        requestStarted ? "眼镜 HTTP GET Wi-Fi 路由已恢复" : "眼镜 HTTP GET Wi-Fi 路由就绪",
                        detail: "host=\(host)\nport=\(port)\npath=\(path)\nrequestStarted=\(requestStarted)",
                        direction: .received
                    )
                    // 路由从 waiting 恢复时，已发送的请求/receive 会由 NWConnection 继续处理；
                    // 再发一次会把两个 HTTP 响应拼在一起。
                    guard !requestStarted else { return }
                    requestStarted = true
                    let payload = Data(request.utf8)
                    connection.send(content: payload, completion: .contentProcessed { sendError in
                        if let sendError {
                            print("[GlassesHTTP] GET send failed: \(sendError.localizedDescription)")
                            DebugLogStore.logWiFi(
                                "眼镜 HTTP GET 发送失败",
                                detail: "host=\(host)\nport=\(port)\npath=\(path)\nerror=\(sendError.localizedDescription)",
                                direction: .received
                            )
                            finish(.failure(GlassesHTTPError.unreachable))
                            return
                        }
                        receiveLoop()
                    })
                case .waiting(let error):
                    waitingGeneration += 1
                    let generation = waitingGeneration
                    DebugLogStore.logWiFi(
                        "眼镜 HTTP GET 临时等待网络",
                        detail: "host=\(host)\nport=\(port)\npath=\(path)\nNWError=\(error.localizedDescription)\nrecoveryGrace=\(String(format: "%.1f", Self.wifiWaitingGrace))s",
                        direction: .received
                    )
                    queue.asyncAfter(deadline: .now() + Self.wifiWaitingGrace) {
                        guard !finished, waitingGeneration == generation else { return }
                        DebugLogStore.logWiFi(
                            "眼镜 HTTP GET 网络等待未恢复",
                            detail: "host=\(host)\nport=\(port)\npath=\(path)\nNWError=\(error.localizedDescription)\nwaited=\(String(format: "%.1f", Self.wifiWaitingGrace))s",
                            direction: .received
                        )
                        finish(.failure(GlassesHTTPError.unreachable))
                    }
                case .failed(let error):
                    waitingGeneration += 1
                    DebugLogStore.logWiFi(
                        "眼镜 HTTP GET 连接失败",
                        detail: "host=\(host)\nport=\(port)\npath=\(path)\nNWError=\(error.localizedDescription)",
                        direction: .received
                    )
                    finish(.failure(GlassesHTTPError.unreachable))
                case .cancelled:
                    if !finished, !received.isEmpty {
                        finish(.success(received))
                    }
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    static func put(
        host: String,
        port: UInt16,
        path: String,
        body: Data,
        timeout: TimeInterval,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        let requestPath = path.hasPrefix("/") ? path : "/" + path

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let queue = DispatchQueue(label: "com.aiglass.rawhttp.put")
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            parameters.prohibitedInterfaceTypes = [.cellular]

            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 80,
                using: parameters
            )
            var finished = false
            let totalBytes = body.count
            var requestStarted = false
            var waitingGeneration = 0

            let finish: (Result<Int, Error>) -> Void = { result in
                queue.async {
                    guard !finished else { return }
                    finished = true
                    connection.cancel()
                    continuation.resume(with: result)
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                if !finished {
                    DebugLogStore.logWiFi(
                        "眼镜 HTTP PUT 超时",
                        detail: "host=\(host)\nport=\(port)\npath=\(requestPath)\ntimeout=\(String(format: "%.1f", timeout))s\nbytes=\(totalBytes)",
                        direction: .received
                    )
                    finish(.failure(GlassesHTTPError.unreachable))
                }
            }

            func receiveResponse() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        print("[GlassesHTTP] PUT connection lost: \(error.localizedDescription)")
                        DebugLogStore.logWiFi(
                            "眼镜 HTTP PUT 连接中断",
                            detail: "host=\(host)\nport=\(port)\npath=\(requestPath)\nerror=\(error.localizedDescription)",
                            direction: .received
                        )
                        finish(.failure(GlassesHTTPError.unreachable))
                        return
                    }
                    guard let data, !data.isEmpty else {
                        if isComplete {
                            finish(.failure(GlassesHTTPError.badResponse))
                        } else {
                            receiveResponse()
                        }
                        return
                    }
                    if let status = parseHTTPStatus(from: data) {
                        finish(.success(status))
                    } else {
                        finish(.failure(GlassesHTTPError.badResponse))
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    waitingGeneration += 1
                    DebugLogStore.logWiFi(
                        requestStarted ? "眼镜 HTTP PUT Wi-Fi 路由已恢复" : "眼镜 HTTP PUT Wi-Fi 路由就绪",
                        detail: "host=\(host)\nport=\(port)\npath=\(requestPath)\nbytes=\(totalBytes)\nrequestStarted=\(requestStarted)",
                        direction: .received
                    )
                    guard !requestStarted else { return }
                    requestStarted = true
                    let headers = "PUT \(requestPath) HTTP/1.1\r\n"
                        + "Host: \(host)\r\n"
                        + "User-Agent: AIGlass/1.0\r\n"
                        + "Content-Type: application/octet-stream\r\n"
                        + "Content-Length: \(totalBytes)\r\n"
                        + "Connection: close\r\n"
                        + "\r\n"
                    var payload = Data(headers.utf8)
                    payload.append(body)
                    connection.send(content: payload, completion: .contentProcessed { sendError in
                        if let sendError {
                            print("[GlassesHTTP] PUT send failed: \(sendError.localizedDescription)")
                            DebugLogStore.logWiFi(
                                "眼镜 HTTP PUT 发送失败",
                                detail: "host=\(host)\nport=\(port)\npath=\(requestPath)\nerror=\(sendError.localizedDescription)",
                                direction: .received
                            )
                            finish(.failure(GlassesHTTPError.unreachable))
                            return
                        }
                        onProgress?(100)
                        receiveResponse()
                    })
                case .waiting(let error):
                    waitingGeneration += 1
                    let generation = waitingGeneration
                    DebugLogStore.logWiFi(
                        "眼镜 HTTP PUT 临时等待网络",
                        detail: "host=\(host)\nport=\(port)\npath=\(requestPath)\nNWError=\(error.localizedDescription)\nrecoveryGrace=\(String(format: "%.1f", Self.wifiWaitingGrace))s",
                        direction: .received
                    )
                    queue.asyncAfter(deadline: .now() + Self.wifiWaitingGrace) {
                        guard !finished, waitingGeneration == generation else { return }
                        DebugLogStore.logWiFi(
                            "眼镜 HTTP PUT 网络等待未恢复",
                            detail: "host=\(host)\nport=\(port)\npath=\(requestPath)\nNWError=\(error.localizedDescription)\nwaited=\(String(format: "%.1f", Self.wifiWaitingGrace))s",
                            direction: .received
                        )
                        finish(.failure(GlassesHTTPError.unreachable))
                    }
                case .failed(let error):
                    waitingGeneration += 1
                    DebugLogStore.logWiFi(
                        "眼镜 HTTP PUT 连接失败",
                        detail: "host=\(host)\nport=\(port)\npath=\(requestPath)\nNWError=\(error.localizedDescription)",
                        direction: .received
                    )
                    finish(.failure(GlassesHTTPError.unreachable))
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }
}

/// 仅建 TCP 连接判断眼镜 HTTP 服务是否已就绪，用于加入热点后的可达性探测。
enum TCPReachability {
    static func canConnect(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let queue = DispatchQueue(label: "com.aiglass.tcpprobe")
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            parameters.prohibitedInterfaceTypes = [.cellular]

            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 80,
                using: parameters
            )
            var finished = false
            let finish: (Bool) -> Void = { reachable in
                queue.async {
                    guard !finished else { return }
                    finished = true
                    connection.cancel()
                    continuation.resume(returning: reachable)
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                if !finished {
                    DebugLogStore.logWiFi(
                        "TCP 探测超时",
                        detail: "host=\(host)\nport=\(port)\ntimeout=\(String(format: "%.1f", timeout))s",
                        direction: .received
                    )
                    finish(false)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .waiting(let error):
                    DebugLogStore.logWiFi(
                        "TCP 探测等待网络",
                        detail: "host=\(host)\nport=\(port)\nNWError=\(error.localizedDescription)",
                        direction: .received
                    )
                case .failed(let error):
                    DebugLogStore.logWiFi(
                        "TCP 探测连接失败",
                        detail: "host=\(host)\nport=\(port)\nNWError=\(error.localizedDescription)",
                        direction: .received
                    )
                    finish(false)
                case .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}

private func parseHTTPStatus(from data: Data) -> Int? {
    guard let headerEnd = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return nil }
    let headerText = String(data: data.subdata(in: data.startIndex..<headerEnd.lowerBound), encoding: .isoLatin1) ?? ""
    guard let statusLine = headerText.components(separatedBy: "\r\n").first else { return nil }
    let parts = statusLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    return Int(parts[1])
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
