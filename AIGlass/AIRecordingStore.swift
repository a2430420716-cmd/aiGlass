import Combine
import Foundation

struct AIRecordingItem: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    let fileName: String
    var filePath: String
    var durationMs: Int64
    let createdAt: TimeInterval
    let userId: String
    var playable: Bool

    var durationText: String {
        // Match the player's rounded total instead of flooring the same recording.
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var timeText: String {
        let date = Date(timeIntervalSince1970: createdAt)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    var totalSeconds: Int {
        max(0, Int((durationMs + 500) / 1000))
    }
}

/// 分用户本地 AI 录音仓库（对齐 Android AiRecordingCacheManager）。
@MainActor
final class AIRecordingStore: ObservableObject {
    static let shared = AIRecordingStore()

    @Published private(set) var recordings: [AIRecordingItem] = []

    private let logTag = "[AIRecordingStore]"
    private var currentUserId = "anonymous"
    private let metadataFileName = "recordings.json"

    private init() {
        reload(userId: currentUserId)
    }

    func updateCurrentUser(_ userId: String?) {
        let normalized = Self.normalizeUserId(userId)
        guard normalized != currentUserId else {
            reload(userId: normalized)
            return
        }
        // Finalize into the original account before switching its recording index.
        Gen1AiRecordingManager.shared.stop()
        currentUserId = normalized
        reload(userId: normalized)
    }

    func reload(userId: String? = nil) {
        if let userId {
            currentUserId = Self.normalizeUserId(userId)
        }
        let dir = recordingsDirectory(for: currentUserId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let metadataURL = dir.appendingPathComponent(metadataFileName)
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([AIRecordingItem].self, from: data) else {
            recordings = []
            return
        }

        var repairedItems: [AIRecordingItem] = []
        var metadataChanged = false
        for var item in decoded {
            let oldURL = URL(fileURLWithPath: item.filePath)
            let storedName = oldURL.lastPathComponent.isEmpty
                ? (item.fileName as NSString).lastPathComponent
                : oldURL.lastPathComponent
            let currentURL = dir.appendingPathComponent(storedName)
            let fallbackURL = dir.appendingPathComponent((item.fileName as NSString).lastPathComponent)

            let resolvedURL: URL?
            if FileManager.default.fileExists(atPath: item.filePath) {
                resolvedURL = oldURL
            } else if FileManager.default.fileExists(atPath: currentURL.path) {
                // App sandbox 根目录可能在重启/更新后变化；按文件名恢复当前容器路径。
                resolvedURL = currentURL
            } else if FileManager.default.fileExists(atPath: fallbackURL.path) {
                resolvedURL = fallbackURL
            } else {
                resolvedURL = nil
            }

            guard let resolvedURL else {
                metadataChanged = true
                print("\(logTag) missing file pruned name=\(storedName)")
                continue
            }
            if item.filePath != resolvedURL.path {
                item.filePath = resolvedURL.path
                metadataChanged = true
            }
            repairedItems.append(item)
        }
        if metadataChanged {
            save(repairedItems)
        }
        recordings = repairedItems
        print("\(logTag) loaded count=\(repairedItems.count) user=\(currentUserId)")
    }

    @discardableResult
    func addRecording(
        fileURL: URL,
        fileName: String,
        durationMs: Int64,
        playable: Bool = true
    ) -> AIRecordingItem? {
        let title = (fileName as NSString).deletingPathExtension
        let item = AIRecordingItem(
            id: UUID().uuidString,
            title: title.isEmpty ? fileName : title,
            fileName: fileName,
            filePath: fileURL.path,
            durationMs: max(0, durationMs),
            createdAt: Date().timeIntervalSince1970,
            userId: currentUserId,
            playable: playable
        )
        var list = recordings
        if list.contains(where: {
            $0.id == item.id
                || $0.filePath == item.filePath
                || $0.fileName.caseInsensitiveCompare(item.fileName) == .orderedSame
        }) {
            print("\(logTag) skip duplicate file=\(item.fileName) path=\(item.filePath)")
            return nil
        }
        list.insert(item, at: 0)
        save(list)
        recordings = list
        print("\(logTag) added id=\(item.id) file=\(fileName) durationMs=\(durationMs)")
        return item
    }

    func updateTitle(id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recordings
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].title = trimmed
        save(list)
        recordings = list
    }

    func deleteRecording(id: String) {
        var list = recordings
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let item = list.remove(at: index)
        if !item.filePath.isEmpty {
            try? FileManager.default.removeItem(atPath: item.filePath)
        }
        save(list)
        recordings = list
        print("\(logTag) deleted id=\(id)")
    }

    func deleteRecordings(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var list = recordings
        let deletingItems = list.filter { ids.contains($0.id) }
        guard !deletingItems.isEmpty else { return }

        deletingItems.forEach { item in
            if !item.filePath.isEmpty {
                try? FileManager.default.removeItem(atPath: item.filePath)
            }
        }
        list.removeAll { ids.contains($0.id) }
        save(list)
        recordings = list
        print("\(logTag) batch deleted count=\(deletingItems.count)")
    }

    func recordingsDirectory(for userId: String? = nil) -> URL {
        let uid = Self.normalizeUserId(userId ?? currentUserId)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("AIGlass", isDirectory: true)
            .appendingPathComponent("ai_recordings", isDirectory: true)
            .appendingPathComponent(uid, isDirectory: true)
    }

    private func save(_ items: [AIRecordingItem]) {
        let dir = recordingsDirectory(for: currentUserId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(metadataFileName)
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("\(logTag) save failed: \(error.localizedDescription)")
        }
    }

    private static func normalizeUserId(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return "anonymous" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let scalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars)
    }
}
