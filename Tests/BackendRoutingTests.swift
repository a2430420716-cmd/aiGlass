import Foundation

// Only the settings types needed by BackendRouting; no UI dependencies.
enum DataStorageRegion { case mainlandChina, usa }
@MainActor
enum AppSettings { static var dataStorageRegion: DataStorageRegion = .mainlandChina }

@main
@MainActor
enum BackendRoutingTests {
    static func main() {
        let suite = "BackendRoutingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let domestic = "https://glasses.mocoviso.com/"
        let overseas = "https://glasses-en.mocoviso.com/"
        let legacy = "https://glasses.kaimou.net/"
        precondition(BackendRouting.resolveRootURL(defaults: defaults).absoluteString == domestic)
        defaults.set(overseas, forKey: BackendRouting.selectedOriginKey)
        precondition(BackendRouting.resolveRootURL(defaults: defaults).absoluteString == overseas)
        defaults.set(legacy, forKey: BackendRouting.selectedOriginKey)
        precondition(BackendRouting.resolveRootURL(defaults: defaults).absoluteString == domestic, "Migrate the previously selected domestic host")

        defaults.set(true, forKey: "auth.isLoggedIn")
        defaults.set("test-token", forKey: "auth.token")
        defaults.set(overseas, forKey: BackendRouting.accountOriginKey)
        precondition(BackendRouting.resolveRootURL(defaults: defaults).absoluteString == overseas, "Keep an overseas account on its own server")
        defaults.set(overseas, forKey: BackendRouting.selectedOriginKey)
        defaults.set(legacy, forKey: BackendRouting.accountOriginKey)
        precondition(BackendRouting.resolveRootURL(defaults: defaults).absoluteString == domestic, "Migrate a logged-in domestic account; account route wins")
        defaults.removeObject(forKey: BackendRouting.accountOriginKey)
        precondition(BackendRouting.resolveRootURL(defaults: defaults).absoluteString == domestic, "Accounts predating stored origins used the domestic server")
        defaults.set("", forKey: "auth.token")
        precondition(BackendRouting.resolveRootURL(defaults: defaults).absoluteString == overseas, "Without a token use the selected region")

        precondition(BackendRouting.validatedOrigin("https://GLASSES.MOCOVISO.COM")?.absoluteString == domestic)
        for invalid in [
            "http://glasses.mocoviso.com", "https://glasses.mocoviso.com.evil.example",
            "https://user@glasses.mocoviso.com", "https://glasses.mocoviso.com:444",
            "https://glasses.mocoviso.com/api/", "https://glasses.mocoviso.com/?x=1",
            "https://glasses.mocoviso.com/#fragment", ""
        ] {
            precondition(BackendRouting.validatedOrigin(invalid) == nil, "Reject invalid origin: \(invalid)")
        }
        testPublicURLs()
        print("Production backend routing tests passed")
    }

    private static func testPublicURLs() {
        let defaults = UserDefaults.standard
        let keys = [BackendRouting.selectedOriginKey, BackendRouting.accountOriginKey, "auth.isLoggedIn", "auth.token"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "auth.isLoggedIn")
        defaults.set(BackendRouting.domesticOrigin, forKey: BackendRouting.selectedOriginKey)
        precondition(BackendRouting.apiURL.absoluteString == "https://glasses.mocoviso.com/api/")
        precondition(BackendRouting.isChina)
        defaults.set(BackendRouting.overseasOrigin, forKey: BackendRouting.selectedOriginKey)
        precondition(BackendRouting.apiURL.absoluteString == "https://glasses-en.mocoviso.com/api/")
        precondition(!BackendRouting.isChina)
    }
}
