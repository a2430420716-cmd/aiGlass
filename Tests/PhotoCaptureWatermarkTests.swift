import Foundation

@main
@MainActor
enum PhotoCaptureWatermarkTests {
    private static var checks = 0

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func main() {
        let suite = "PhotoCaptureWatermarkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var store = PhotoCaptureWatermarkStore(defaults: defaults)
        let account = "account-a"
        let device = "device-a"
        let names = ["2026-10-28-09-30-01.jpg", "2026-10-28-09-30-12.jpg", "2026-10-28-09-30-21.jpg"]
        // Phone time deliberately differs from the glasses clock.
        let configs = [3, 2, 1].enumerated().map { index, style in
            PhotoWatermarkConfiguration(enabled: index != 2, style: style,
                capturedAt: Date(timeIntervalSince1970: 1_900_000_000 + Double(index)))
        }
        for index in names.indices {
            let id = UUID()
            check(store.begin(id: id, account: account, device: device,
                baselineNames: Array(names.prefix(index)), baselineCount: index,
                configuration: configs[index]), "Capture snapshot must persist")
            store.confirm(id: id)
        }
        // Restart before import; authoritative list order need not be chronological.
        store = PhotoCaptureWatermarkStore(defaults: defaults)
        let result = store.bind(fileNames: Array(names.reversed()), account: account, device: device)
        check(result.hasPrefix("bound=3"), "Exact confirmed batch binds after restart")
        for index in names.indices {
            check(store.configuration(fileName: names[index], account: account, device: device) == configs[index],
                  "Each photo keeps its own style, enabled flag and capture date")
        }
        check(store.configuration(fileName: names[0], account: "another-account", device: device) == nil,
              "Another account cannot inherit a watermark")
        check(store.configuration(fileName: names[0], account: account, device: "another-device") == nil,
              "Another device cannot inherit a watermark")
        store = PhotoCaptureWatermarkStore(defaults: defaults)
        _ = store.bind(fileNames: names, account: account, device: device)
        check(store.configuration(fileName: names[0], account: account, device: device) == configs[0],
              "An import retry retains the same mapping until files disappear from the device")
        _ = store.bind(fileNames: Array(names.dropFirst()), account: account, device: device)
        check(store.configuration(fileName: names[0], account: account, device: device) == nil,
              "An authoritative list prunes deleted files")

        func ambiguous(_ label: String, baseline: [String], count: Int, listed: [String], confirmed: Bool = true) {
            let id = UUID()
            _ = store.begin(id: id, account: account, device: label, baselineNames: baseline,
                baselineCount: count, configuration: configs[0])
            if confirmed { store.confirm(id: id) }
            let result = store.bind(fileNames: listed, account: account, device: label)
            check(result.contains("no_assignment"), "Ambiguous \(label) must not guess")
            for name in listed {
                check(store.configuration(fileName: name, account: account, device: label) == nil,
                      "Ambiguous \(label) must not assign another file")
            }
            _ = store.bind(fileNames: [names[0]], account: account, device: label)
            check(store.configuration(fileName: names[0], account: account, device: label) == nil,
                  "An unmatched snapshot cannot leak into a later batch")
        }
        ambiguous("partial-baseline", baseline: [], count: 2, listed: names)
        ambiguous("extra-hardware-photo", baseline: [], count: 0, listed: Array(names.prefix(2)))
        ambiguous("missing-baseline", baseline: ["old.jpg"], count: 1, listed: Array(names.prefix(2)))
        ambiguous("video-interleaved", baseline: [], count: 0, listed: ["2026-10-28-09-30-01.mp4"])
        ambiguous("unconfirmed", baseline: [], count: 0, listed: [names[0]], confirmed: false)
        ambiguous("unknown-order", baseline: [], count: 0, listed: ["unrecognized.jpg"])

        let cancelled = UUID()
        _ = store.begin(id: cancelled, account: account, device: "cancelled", baselineNames: [],
            baselineCount: 0, configuration: configs[0])
        store.cancel(id: cancelled)
        _ = store.bind(fileNames: [names[0]], account: account, device: "cancelled")
        check(store.configuration(fileName: names[0], account: account, device: "cancelled") == nil,
              "A rejected photo cannot own a later file")

        let mixed = UUID()
        _ = store.begin(id: mixed, account: account, device: "existing-video", baselineNames: ["old.mp4"],
            baselineCount: 1, configuration: configs[1])
        store.confirm(id: mixed)
        _ = store.bind(fileNames: [names[0], "old.mp4"], account: account, device: "existing-video")
        check(store.configuration(fileName: names[0], account: account, device: "existing-video") == configs[1],
              "Existing videos in the baseline do not prevent photo matching")
        print("Photo capture watermark tests passed: \(checks)")
    }
}
