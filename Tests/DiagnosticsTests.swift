import Foundation

enum L10n {
    nonisolated static func t(_ zh: String, _ en: String) -> String { en }
}

// Export metadata is fixed for the host-side logger test. The app implementation
// also opens UIKit URLs and is covered by the separate full iOS compilation.
enum AppBundleInfo {
    static let shortVersion = "1.1.7"
    static let buildNumber = "182"
}

@main struct DiagnosticsTests {
    @MainActor static func main() async throws {
        let expected = CommandLine.arguments[1] == "enabled"
        precondition(AppDiagnostics.isEnabled == expected, "Compile flags must select the requested policy")

        var evaluations = 0
        func message() -> String { evaluations += 1; return "DIAGNOSTICS_CONSOLE_MARKER" }
        print(message())
        precondition(evaluations == (expected ? 1 : 0), "Production console calls must not evaluate log strings")
        let packet = AstraA1BleProtocol.buildPacket(command: "getdevstat")
        DebugLogStore.logHTTPSent(method: "POST", url: "https://example.invalid/user/userinfo", body: "sensitive body")
        DebugLogStore.logHTTPReceived(method: "POST", url: "https://example.invalid/user/userinfo", statusCode: 200, body: "response")
        DebugLogStore.logHTTPEvent("http marker", detail: "value")
        DebugLogStore.logTranslation("translation marker")
        DebugLogStore.logShare("share marker")
        DebugLogStore.logBLESent(packet)
        DebugLogStore.logBLEReceived(packet)
        DebugLogStore.logBLERawReceived(data: packet, peripheralID: "device", characteristicID: "AE3C", context: "test", capturedAt: Date())
        DebugLogStore.logBLEEvent("ble marker")
        DebugLogStore.logConnect("connection marker")
        DebugLogStore.logWiFi("wifi marker")
        try await Task.sleep(nanoseconds: 50_000_000)

        let store = DebugLogStore.shared
        let counts = [store.httpEntries.count, store.bleEntries.count, store.wifiEntries.count, store.connectEntries.count]
        precondition(counts == (expected ? [5, 4, 2, 1] : [0, 0, 0, 0]), "All log channels follow the build policy")
        let data = Data("sensitive body".utf8)
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        precondition((DebugLogStore.utf8Body(from: data) != nil) == expected)
        precondition((DebugLogStore.jsonBody(["account": "test"]) != nil) == expected)
        precondition((!DebugLogStore.headerFields(from: response).isEmpty) == expected)
        for channel in [DebugLogStore.Channel.http, .ble, .wifi, .connect] {
            precondition((!store.exportText(for: channel).isEmpty) == expected)
            do {
                let url = try store.exportFileURL(for: channel)
                precondition(expected, "Production must not create log export files")
                let exported = try String(contentsOf: url, encoding: .utf8)
                precondition(exported.contains("调试日志"))
                try FileManager.default.removeItem(at: url)
            } catch {
                precondition(!expected, "Testing log exports must work")
            }
        }
        Swift.print("Diagnostics \(expected ? "enabled" : "disabled"): console, 11 log entry points, four channels, formatting and export passed")
    }
}
