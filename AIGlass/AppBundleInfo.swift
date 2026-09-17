import Foundation
import UIKit

enum AppBundleInfo {
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var displayVersion: String {
        displayVersion(shortVersion)
    }

    /// “关于”页展示：营销版本后追加构建号，不影响 OTA / App 更新的版本比较。
    static var aboutDisplayVersion: String {
        "\(displayVersion) (\(buildNumber))"
    }

    static func displayVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        if trimmed.hasPrefix("V") || trimmed.hasPrefix("v") {
            return trimmed
        }
        return "V\(trimmed)"
    }

    static var appStoreURL: URL? {
        if let appStoreID = Bundle.main.object(forInfoDictionaryKey: "AppStoreAppID") as? String,
           !appStoreID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(string: "https://apps.apple.com/app/id\(appStoreID)")
        }
        return URL(string: "https://apps.apple.com/search?term=MOCO%20AI%20Glasses")
    }

    static func openAppStore() {
        guard let url = appStoreURL else { return }
        UIApplication.shared.open(url)
    }
}
