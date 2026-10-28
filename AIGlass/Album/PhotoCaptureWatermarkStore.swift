import Foundation

nonisolated struct PhotoWatermarkConfiguration: Codable, Equatable, Sendable {
    let enabled: Bool
    let style: Int
    let capturedAt: Date
}

/// Capture snapshots survive app restarts. Only an unambiguous file-list difference
/// may bind a snapshot to a device filename; ambiguous batches keep the import fallback.
@MainActor
final class PhotoCaptureWatermarkStore {
    static let shared = PhotoCaptureWatermarkStore()

    nonisolated private struct Capture: Codable {
        let id: UUID
        let configuration: PhotoWatermarkConfiguration
        let baselineNames: [String]
        let baselineCount: Int
        var confirmed: Bool
    }

    nonisolated private struct Batch: Codable {
        let account: String
        let device: String
        var captures: [Capture] = []
        var files: [String: PhotoWatermarkConfiguration] = [:]
    }

    private let defaults: UserDefaults
    private let key = "album.photoCaptureWatermarks.v1"
    private var batches: [Batch]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        batches = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Batch].self, from: $0) } ?? []
    }

    @discardableResult
    func begin(id: UUID, account: String, device: String, baselineNames: [String], baselineCount: Int,
               configuration: PhotoWatermarkConfiguration) -> Bool {
        if !batches.contains(where: { $0.account == account && $0.device == device }) {
            batches.append(Batch(account: account, device: device))
        }
        guard let index = index(account: account, device: device) else { return false }
        batches[index].captures.append(Capture(id: id, configuration: configuration,
            baselineNames: baselineNames, baselineCount: baselineCount, confirmed: false))
        return save()
    }

    func confirm(id: UUID) {
        for i in batches.indices {
            if let j = batches[i].captures.firstIndex(where: { $0.id == id }) {
                batches[i].captures[j].confirmed = true
                _ = save()
                return
            }
        }
    }

    func cancel(id: UUID) {
        for i in batches.indices { batches[i].captures.removeAll { $0.id == id } }
        _ = save()
    }

    /// Never guess by phone time: device clocks and filename timezones can differ.
    @discardableResult
    func bind(fileNames: [String], account: String, device: String) -> String {
        guard let i = index(account: account, device: device) else { return "no_capture_snapshots" }
        let listed = Set(fileNames)
        // Keep successful imports mapped until the device actually removes them.
        // A failed transfer-finish can leave the same files available for another import.
        batches[i].files = batches[i].files.filter { listed.contains($0.key) }
        guard let first = batches[i].captures.first else {
            _ = save()
            return "no_capture_snapshots retained=\(batches[i].files.count)"
        }
        let captures = batches[i].captures
        guard captures.allSatisfy(\.confirmed) else {
            return discardUnmatched(at: i, reason: "unconfirmed_capture; no_assignment")
        }
        let baseline = Set(first.baselineNames)
        guard first.baselineCount >= 0, baseline.count == first.baselineCount, baseline.isSubset(of: listed),
              listed.count == first.baselineCount + captures.count else {
            return discardUnmatched(at: i, reason: "ambiguous_file_count baseline=\(first.baselineCount) cached=\(baseline.count) captures=\(captures.count) listed=\(listed.count); no_assignment")
        }
        let added = listed.subtracting(baseline).sorted()
        // Documented Gen1 timestamp names sort chronologically without relying on phone time.
        let pattern = #"^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}\.(jpg|jpeg|png)$"#
        guard added.count == captures.count,
              added.allSatisfy({ $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }) else {
            return discardUnmatched(at: i, reason: "ambiguous_media_order; no_assignment")
        }
        for (name, capture) in zip(added, captures) { batches[i].files[name] = capture.configuration }
        batches[i].captures.removeAll()
        return save() ? "bound=\(added.count) evidence=confirmed_captures_and_exact_file_list_difference" : "persistence_failed"
    }

    func configuration(fileName: String, account: String, device: String) -> PhotoWatermarkConfiguration? {
        guard let i = index(account: account, device: device) else { return nil }
        return batches[i].files[fileName]
    }

    private func index(account: String, device: String) -> Int? {
        batches.firstIndex { $0.account == account && $0.device == device }
    }

    private func discardUnmatched(at index: Int, reason: String) -> String {
        // This authoritative import consumes the matching opportunity. Never carry
        // unmatched shots forward to unrelated files or a reset device clock.
        batches[index].captures.removeAll()
        _ = save()
        return reason
    }

    private func save() -> Bool {
        guard let data = try? JSONEncoder().encode(batches) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}
