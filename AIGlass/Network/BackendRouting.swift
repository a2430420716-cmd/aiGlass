import Foundation

/// Account tokens must stay on the origin which issued them. Only the dispatch
/// request uses a fixed bootstrap origin; every business API uses the selection.
enum BackendRouting {
    nonisolated static let domesticOrigin = "https://glasses.kaimou.net"
    nonisolated static let overseasOrigin = "https://glasses-en.mocoviso.com"
    nonisolated static let selectedOriginKey = "server.selectedOrigin"
    nonisolated static let accountOriginKey = "auth.serverOrigin"

    nonisolated static func validatedOrigin(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let host = parts.host,
              ["glasses.kaimou.net", "glasses-en.mocoviso.com"].contains(host) else { return nil }
        return URL(string: "https://" + host + "/")
    }

    nonisolated static var rootURL: URL {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "auth.isLoggedIn"),
           !(defaults.string(forKey: "auth.token") ?? "").isEmpty {
            // Existing releases used the domestic origin for business APIs.
            return validatedOrigin(defaults.string(forKey: accountOriginKey) ?? domesticOrigin)
                ?? URL(string: domesticOrigin + "/")!
        }
        return validatedOrigin(defaults.string(forKey: selectedOriginKey) ?? "")
            ?? URL(string: domesticOrigin + "/")!
    }

    nonisolated static var apiURL: URL { rootURL.appendingPathComponent("api", isDirectory: true) }
    nonisolated static var isChina: Bool { rootURL.host == "glasses.kaimou.net" }

    /// Pin the current route before persisting a newly issued token.
    static func pinAccountOrigin() {
        let origin = rootURL.absoluteString
        UserDefaults.standard.set(origin, forKey: accountOriginKey)
        UserDefaults.standard.set(origin, forKey: selectedOriginKey)
    }
}

@MainActor
enum ServerDispatch {
    private struct Result: Decodable {
        let is_china: Bool
        let domain: String
    }

    private static var inFlight: Task<Void, Error>?

    static func resolveBeforeLogin() async throws {
        let defaults = UserDefaults.standard
        // Upgrades and established accounts must never be rerouted by public IP.
        if defaults.bool(forKey: "auth.isLoggedIn"),
           !(defaults.string(forKey: "auth.token") ?? "").isEmpty { return }
        if let cached = defaults.string(forKey: BackendRouting.selectedOriginKey),
           BackendRouting.validatedOrigin(cached) != nil { return }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await fetch() }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }

    private static func fetch() async throws {
        #if DEBUG
        let origin = BackendRouting.domesticOrigin
        #else
        // Release archives (including App Store exports) bootstrap overseas.
        let origin = BackendRouting.overseasOrigin
        #endif
        let url = URL(string: origin + "/api/dispatch/checkIp")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        AppRequestHeaders.apply(to: &request)
        // No account token, and no persisted cookies for the bootstrap request.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        DebugLogStore.logHTTPSent(method: "GET", url: url.absoluteString, body: nil, headers: request.allHTTPHeaderFields)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        let envelope = try JSONDecoder().decode(APIResponse<Result>.self, from: data)
        guard envelope.code == 0, let result = envelope.result,
              let selected = BackendRouting.validatedOrigin(result.domain),
              result.is_china == (selected.host == "glasses.kaimou.net") else {
            throw APIError.invalidResponse
        }
        try Task.checkCancellation()
        // Do not let a delayed bootstrap overwrite a login completed elsewhere.
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "auth.isLoggedIn") else { return }
        defaults.set(selected.absoluteString, forKey: BackendRouting.selectedOriginKey)
        DebugLogStore.logHTTPReceived(method: "GET", url: url.absoluteString, statusCode: http.statusCode, body: "selectedOrigin=\(selected.absoluteString) isChina=\(result.is_china)")
    }
}
