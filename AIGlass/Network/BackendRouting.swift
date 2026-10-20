import Foundation

/// Account tokens stay on the origin which issued them. Before login, the user
/// explicitly selects the server region.
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

    static func selectRegionBeforeLogin(_ region: DataStorageRegion) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "auth.isLoggedIn") else { return }
        let origin = region == .mainlandChina ? domesticOrigin : overseasOrigin
        AppSettings.dataStorageRegion = region
        defaults.set(origin, forKey: selectedOriginKey)
    }

    /// Pin the current route before persisting a newly issued token.
    static func pinAccountOrigin() {
        let origin = rootURL.absoluteString
        UserDefaults.standard.set(origin, forKey: accountOriginKey)
        UserDefaults.standard.set(origin, forKey: selectedOriginKey)
    }
}
