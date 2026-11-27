import Foundation

/// 所有公网请求共用 Header。每次发请求即时读取设置，切换语言后无需重启。
enum AppRequestHeaders {
    nonisolated static var acceptLanguageValue: String {
        L10n.usesEnglish ? "en" : "zh"
    }

    nonisolated static func apply(to request: inout URLRequest) {
        request.setValue(acceptLanguageValue, forHTTPHeaderField: "Accept-Language")
    }
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(message: String, code: Int)
    case decoding
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L10n.t("请求地址无效", "Invalid request URL")
        case .invalidResponse:
            return L10n.t("服务器响应异常", "Unexpected server response")
        case .server(let message, _):
            return message
        case .decoding:
            return L10n.t("数据解析失败", "Failed to parse data")
        case .network:
            return L10n.t(
                "网络连接异常，请检查网络后重试",
                "There is a network connection error. Check your network connection and try again."
            )
        }
    }
}

struct APIResponse<T: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let result: T?
}

struct APIStatus: Decodable {
    let code: Int
    let msg: String?
}

struct EmptyResult: Decodable {}

enum APIClient {
    /// 注意末尾必须带 `/`，否则 `URL(relativeTo:)` 会把 `api` 当成文件名替换掉。
    static var baseURL: URL { BackendRouting.apiURL }

    static func post<T: Decodable>(
        path: String,
        body: [String: Any],
        authorization: String? = nil,
        as type: T.Type = T.self
    ) async throws -> T? {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: trimmedPath, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidURL
        }

        print("[API] POST \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        AppRequestHeaders.apply(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization, !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        return try await sendPost(request, loggedBody: body, as: type)
    }

    /// Text-only multipart form for endpoints that require form-data without a file.
    static func postMultipart<T: Decodable>(
        path: String,
        fields: [String: String],
        authorization: String? = nil,
        sensitiveFields: Set<String> = [],
        as type: T.Type = T.self
    ) async throws -> T? {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: trimmedPath, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        AppRequestHeaders.apply(to: &request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let authorization, !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 20

        let loggedBody = fields.reduce(into: [String: Any]()) { result, item in
            result[item.key] = sensitiveFields.contains(item.key) ? "<redacted>" : item.value
        }
        return try await sendPost(request, loggedBody: loggedBody, as: type)
    }

    private static func sendPost<T: Decodable>(
        _ request: URLRequest,
        loggedBody: [String: Any],
        as type: T.Type
    ) async throws -> T? {
        guard let url = request.url else { throw APIError.invalidURL }
        DebugLogStore.logHTTPSent(
            method: "POST",
            url: url.absoluteString,
            body: DebugLogStore.jsonBody(loggedBody),
            headers: request.allHTTPHeaderFields
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await PublicHTTPDiagnostics.data(for: request, session: .shared)
        } catch {
            DebugLogStore.logHTTPReceived(
                method: "POST",
                url: url.absoluteString,
                statusCode: nil,
                body: nil,
                error: error.localizedDescription
            )
            throw APIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            DebugLogStore.logHTTPReceived(
                method: "POST",
                url: url.absoluteString,
                statusCode: nil,
                body: DebugLogStore.utf8Body(from: data),
                error: "invalid response"
            )
            throw APIError.invalidResponse
        }

        DebugLogStore.logHTTPReceived(
            method: "POST",
            url: url.absoluteString,
            statusCode: http.statusCode,
            body: DebugLogStore.utf8Body(from: data),
            headers: DebugLogStore.headerFields(from: http)
        )

        guard (200...299).contains(http.statusCode) else {
            throw APIError.server(
                message: L10n.t("网络错误(\(http.statusCode))", "Network error (\(http.statusCode))"),
                code: http.statusCode
            )
        }

        let decoder = JSONDecoder()

        // 先解析 code/msg，兼容 result 结构不确定的情况
        guard let status = try? decoder.decode(APIStatus.self, from: data) else {
            throw APIError.decoding
        }

        guard status.code == 0 else {
            throw APIError.server(
                message: status.msg?.isEmpty == false ? status.msg! : L10n.t("请求失败", "Request failed"),
                code: status.code
            )
        }

        if let apiResponse = try? decoder.decode(APIResponse<T>.self, from: data) {
            return apiResponse.result
        }

        return nil
    }

    /// POST `application/x-www-form-urlencoded`，支持指定完整接口地址。
    /// `sensitiveFields` 仅影响调试日志，请求仍发送原值。
    static func postForm<T: Decodable>(
        url: URL,
        body: [String: String],
        authorization: String? = nil,
        sensitiveFields: Set<String> = [],
        as type: T.Type = T.self
    ) async throws -> T? {
        var formComponents = URLComponents()
        formComponents.queryItems = body
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        // Form decoders treat + as a space, even when URL query encoding leaves it literal.
        guard let encodedBody = formComponents.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").data(using: .utf8) else {
            throw APIError.invalidURL
        }

        print("[API] POST FORM \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        AppRequestHeaders.apply(to: &request)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization, !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = encodedBody
        request.timeoutInterval = 20

        let loggedBody = body.reduce(into: [String: Any]()) { result, item in
            result[item.key] = sensitiveFields.contains(item.key) ? "<redacted>" : item.value
        }
        DebugLogStore.logHTTPSent(
            method: "POST",
            url: url.absoluteString,
            body: DebugLogStore.jsonBody(loggedBody),
            headers: request.allHTTPHeaderFields
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await PublicHTTPDiagnostics.data(for: request, session: .shared)
        } catch {
            DebugLogStore.logHTTPReceived(
                method: "POST",
                url: url.absoluteString,
                statusCode: nil,
                body: nil,
                error: error.localizedDescription
            )
            throw APIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            DebugLogStore.logHTTPReceived(
                method: "POST",
                url: url.absoluteString,
                statusCode: nil,
                body: DebugLogStore.utf8Body(from: data),
                error: "invalid response"
            )
            throw APIError.invalidResponse
        }

        DebugLogStore.logHTTPReceived(
            method: "POST",
            url: url.absoluteString,
            statusCode: http.statusCode,
            body: DebugLogStore.utf8Body(from: data),
            headers: DebugLogStore.headerFields(from: http)
        )

        guard (200...299).contains(http.statusCode) else {
            throw APIError.server(
                message: L10n.t("网络错误(\(http.statusCode))", "Network error (\(http.statusCode))"),
                code: http.statusCode
            )
        }

        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(APIStatus.self, from: data) else {
            throw APIError.decoding
        }
        guard status.code == 0 else {
            throw APIError.server(
                message: status.msg?.isEmpty == false ? status.msg! : L10n.t("请求失败", "Request failed"),
                code: status.code
            )
        }
        // Write-only endpoints may return null, [] or omit result on success.
        if T.self == EmptyResult.self { return nil }
        guard let apiResponse = try? decoder.decode(APIResponse<T>.self, from: data),
              let result = apiResponse.result else {
            throw APIError.decoding
        }
        return result
    }

    /// 返回原始响应数据，便于调试未知结构的接口。
    static func postRaw(
        path: String,
        body: [String: Any] = [:],
        authorization: String? = nil
    ) async throws -> Data {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: trimmedPath, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidURL
        }

        print("[API] POST \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        AppRequestHeaders.apply(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization, !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        DebugLogStore.logHTTPSent(
            method: "POST",
            url: url.absoluteString,
            body: DebugLogStore.jsonBody(body),
            headers: request.allHTTPHeaderFields
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await PublicHTTPDiagnostics.data(for: request, session: .shared)
        } catch {
            DebugLogStore.logHTTPReceived(
                method: "POST",
                url: url.absoluteString,
                statusCode: nil,
                body: nil,
                error: error.localizedDescription
            )
            throw APIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            DebugLogStore.logHTTPReceived(
                method: "POST",
                url: url.absoluteString,
                statusCode: nil,
                body: DebugLogStore.utf8Body(from: data),
                error: "invalid response"
            )
            throw APIError.invalidResponse
        }

        DebugLogStore.logHTTPReceived(
            method: "POST",
            url: url.absoluteString,
            statusCode: http.statusCode,
            body: DebugLogStore.utf8Body(from: data),
            headers: DebugLogStore.headerFields(from: http)
        )

        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw APIError.server(
                message: L10n.t(
                    "网络错误(\(http.statusCode)) \(bodyText)",
                    "Network error (\(http.statusCode)) \(bodyText)"
                ),
                code: http.statusCode
            )
        }

        return data
    }

    /// GET 原始响应；用于分页查询等 query-string 接口。
    static func getRaw(
        path: String,
        queryItems: [URLQueryItem] = [],
        authorization: String? = nil,
        session: URLSession = .shared,
        timeout: TimeInterval = 20
    ) async throws -> Data {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let relativeURL = URL(string: trimmedPath, relativeTo: baseURL),
              var components = URLComponents(
                url: relativeURL.absoluteURL,
                resolvingAgainstBaseURL: false
              ) else {
            throw APIError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        print("[API] GET \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        AppRequestHeaders.apply(to: &request)
        if let authorization, !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeout
        DebugLogStore.logHTTPSent(
            method: "GET",
            url: url.absoluteString,
            body: nil,
            headers: request.allHTTPHeaderFields
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await PublicHTTPDiagnostics.data(for: request, session: session)
        } catch {
            DebugLogStore.logHTTPReceived(
                method: "GET",
                url: url.absoluteString,
                statusCode: nil,
                body: nil,
                error: error.localizedDescription
            )
            throw APIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        DebugLogStore.logHTTPReceived(
            method: "GET",
            url: url.absoluteString,
            statusCode: http.statusCode,
            body: DebugLogStore.utf8Body(from: data),
            headers: DebugLogStore.headerFields(from: http)
        )
        guard (200...299).contains(http.statusCode) else {
            throw APIError.server(
                message: L10n.t("网络错误(\(http.statusCode))", "Network error (\(http.statusCode))"),
                code: http.statusCode
            )
        }

        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(APIStatus.self, from: data) else {
            throw APIError.decoding
        }
        guard status.code == 0 else {
            throw APIError.server(
                message: status.msg?.isEmpty == false ? status.msg! : L10n.t("请求失败", "Request failed"),
                code: status.code
            )
        }
        return data
    }

    static func uploadMultipart(
        path: String,
        fileData: Data,
        fileName: String,
        mimeType: String,
        fieldName: String = "file",
        formFields: [String: String] = [:],
        queryItems: [URLQueryItem] = [],
        authorization: String? = nil,
        additionalHeaders: [String: String] = [:],
        timeout: TimeInterval = 60
    ) async throws -> Data {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: URL(string: trimmedPath, relativeTo: baseURL)!.absoluteURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        print("[API] UPLOAD \(url.absoluteString)")

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in formFields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
                    .data(using: .utf8)!
            )
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        AppRequestHeaders.apply(to: &request)
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        if let authorization, !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = timeout

        DebugLogStore.logHTTPSent(
            method: "UPLOAD",
            url: url.absoluteString,
            body: "multipart file=\(fileName) bytes=\(fileData.count) mime=\(mimeType) fields=\(formFields)",
            headers: request.allHTTPHeaderFields
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await PublicHTTPDiagnostics.data(for: request, session: .shared)
        } catch {
            DebugLogStore.logHTTPReceived(
                method: "UPLOAD",
                url: url.absoluteString,
                statusCode: nil,
                body: nil,
                error: error.localizedDescription
            )
            throw APIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            DebugLogStore.logHTTPReceived(
                method: "UPLOAD",
                url: url.absoluteString,
                statusCode: nil,
                body: DebugLogStore.utf8Body(from: data),
                error: "invalid response"
            )
            throw APIError.invalidResponse
        }

        DebugLogStore.logHTTPReceived(
            method: "UPLOAD",
            url: url.absoluteString,
            statusCode: http.statusCode,
            body: DebugLogStore.utf8Body(from: data),
            headers: DebugLogStore.headerFields(from: http)
        )

        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw APIError.server(
                message: L10n.t(
                    "网络错误(\(http.statusCode)) \(bodyText)",
                    "Network error (\(http.statusCode)) \(bodyText)"
                ),
                code: http.statusCode
            )
        }

        return data
    }
}
