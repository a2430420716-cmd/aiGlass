import AVFoundation
import Combine
import Foundation
import UIKit

struct StoredMediaItem: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let isVideo: Bool
    let createdAt: Date
    var isFavorite: Bool
    let durationSeconds: Double?
    /// Optional for backward compatibility with manifests written before this flag.
    var videoPlaybackUnavailable: Bool? = nil

    var originalFileName: String { "\(id.uuidString)_\(fileName)" }
    var thumbnailFileName: String { "\(id.uuidString)_thumb.jpg" }
}

@MainActor
final class MediaLibrary: ObservableObject {
    static let shared = MediaLibrary()

    @Published private(set) var items: [StoredMediaItem] = []

    private let manifestName = "manifest.json"
    private let fileManager = FileManager.default
    private var gen1ImportTasks: [UUID: (fileName: String, task: Task<StoredMediaItem, Swift.Error>)] = [:]

    private var rootURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Album", isDirectory: true)
    }

    private var originalsURL: URL { rootURL.appendingPathComponent("originals", isDirectory: true) }
    private var thumbnailsURL: URL { rootURL.appendingPathComponent("thumbnails", isDirectory: true) }
    private var manifestURL: URL { rootURL.appendingPathComponent(manifestName) }
    private var gen1Archive: Gen1MediaStaging {
        Gen1MediaStaging(rootURL: rootURL.appendingPathComponent("gen1-originals", isDirectory: true))
    }

    private init() {
        ensureDirectories()
        loadManifest()
    }

    func originalURL(for item: StoredMediaItem) -> URL {
        originalsURL.appendingPathComponent(item.originalFileName)
    }

    func thumbnailURL(for item: StoredMediaItem) -> URL {
        thumbnailsURL.appendingPathComponent(item.thumbnailFileName)
    }

    /// Unmodified Gen1 source, separate from the rotated file used by the album UI.
    func preservedGen1OriginalURL(for item: StoredMediaItem) -> URL? {
        gen1Archive.preservedOriginalURL(itemID: item.id)
    }

    func sections(filter: AlbumFilter) -> [AlbumSection] {
        let calendar = Calendar.current
        let filtered = items.filter { item in
            switch filter {
            case .all: return true
            case .photos: return !item.isVideo
            case .videos: return item.isVideo
            }
        }

        let todayLabel = L10n.t("今天", "Today")
        let yesterdayLabel = L10n.t("昨天", "Yesterday")
        let grouped = Dictionary(grouping: filtered) { item -> String in
            if calendar.isDateInToday(item.createdAt) { return todayLabel }
            if calendar.isDateInYesterday(item.createdAt) { return yesterdayLabel }
            let formatter = DateFormatter()
            if AppLanguageManager.shared.usesEnglish {
                formatter.locale = Locale(identifier: "en_US")
                formatter.dateFormat = "MMM d"
            } else {
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "M月d日"
            }
            return formatter.string(from: item.createdAt)
        }

        return grouped.keys.sorted { lhs, rhs in
            let order = [todayLabel: 0, yesterdayLabel: 1]
            let l = order[lhs] ?? 2
            let r = order[rhs] ?? 2
            if l != r { return l < r }
            return lhs > rhs
        }.compactMap { title in
            guard let list = grouped[title], !list.isEmpty else { return nil }
            let sorted = list.sorted { $0.createdAt > $1.createdAt }
            return AlbumSection(title: title, items: sorted)
        }
    }

    @discardableResult
    func importOriginal(data: Data, fileName: String) async throws -> StoredMediaItem {
        ensureDirectories()
        let id = UUID()
        let isVideo = Self.isVideoFile(fileName)
        let item = StoredMediaItem(
            id: id,
            fileName: fileName,
            isVideo: isVideo,
            createdAt: Date(),
            isFavorite: false,
            durationSeconds: nil
        )

        let originalURL = originalURL(for: item)
        if isVideo {
            let tempURL = originalsURL.appendingPathComponent("tmp_\(id.uuidString)_\(fileName)")
            let stabilizedURL = originalsURL.appendingPathComponent("tmp_\(id.uuidString)_eis.mp4")
            try data.write(to: tempURL, options: .atomic)
            await Self.logVideoDuration(url: tempURL, fileName: fileName, stage: "downloaded_original")
            defer {
                try? fileManager.removeItem(at: tempURL)
                try? fileManager.removeItem(at: stabilizedURL)
            }

            var originalIsReadable = true
            do {
                try await Gen1VideoOriginalValidator.validateVideoOriginal(tempURL)
            } catch is Gen1VideoOriginalValidator.UnreadableVideoError {
                originalIsReadable = false
            }
            if !originalIsReadable {
                try Task.checkCancellation()
                try fileManager.copyItem(at: tempURL, to: originalURL)
                let unreadableItem = StoredMediaItem(
                    id: id, fileName: fileName, isVideo: true, createdAt: Date(),
                    isFavorite: false, durationSeconds: nil, videoPlaybackUnavailable: true
                )
                try Self.generateUnavailableVideoThumbnail(to: thumbnailURL(for: unreadableItem))
                try Task.checkCancellation()
                try commitGen1Item(unreadableItem)
                return unreadableItem
            }

            let stabilized = await PixSmartVideoEIS.stabilizeVideo(
                from: tempURL,
                to: stabilizedURL
            )
            if stabilized {
                await Self.logVideoDuration(url: stabilizedURL, fileName: fileName, stage: "stabilized")
            }
            do {
                if stabilized {
                    // EIS 输出只有视频轨：从原文件补回音轨，再保持现有导入方向。
                    try await MediaOrientationFixer.rotateVideoCounterClockwise90(
                        from: stabilizedURL,
                        audioFrom: tempURL,
                        to: originalURL
                    )
                } else {
                    try await MediaOrientationFixer.rotateVideoCounterClockwise90(
                        from: tempURL,
                        to: originalURL
                    )
                }
            } catch {
                // EIS/合成失败时再尝试原视频旋转；仍失败才原样保存，始终不阻断导入。
                print("[MediaLibrary] processed video compose failed, fallback: \(error.localizedDescription)")
                try? fileManager.removeItem(at: originalURL)
                do {
                    try await MediaOrientationFixer.rotateVideoCounterClockwise90(
                        from: tempURL,
                        to: originalURL
                    )
                } catch {
                    print("[MediaLibrary] video rotate failed, saving original: \(error.localizedDescription)")
                    try? fileManager.removeItem(at: originalURL)
                    try data.write(to: originalURL, options: .atomic)
                }
            }
        } else {
            var photoData = try MediaOrientationFixer.rotateImageDataCounterClockwise90(data, fileName: fileName)
            // 旋转后再做 PixSmart 纯图像 EIS 防抖；失败则保留旋转结果。
            photoData = PixSmartEIS.stabilizePhotoData(photoData)
            // EIS 后再按眼镜设置叠加图片水印。
            photoData = PhotoWatermarkApplier.applyIfNeeded(photoData, capturedAt: Date())
            try photoData.write(to: originalURL, options: .atomic)
        }

        var finalItem = item
        if isVideo {
            await Self.logVideoDuration(url: originalURL, fileName: fileName, stage: "album_final")
            let duration = Self.videoDuration(url: originalURL)
            finalItem = StoredMediaItem(
                id: id,
                fileName: fileName,
                isVideo: true,
                createdAt: Date(),
                isFavorite: false,
                durationSeconds: duration
            )
            try Self.generateVideoThumbnail(from: originalURL, to: thumbnailURL(for: finalItem))
        } else if let rotatedData = try? Data(contentsOf: originalURL) {
            try Self.generatePhotoThumbnail(from: rotatedData, to: thumbnailURL(for: item))
        }

        items.insert(finalItem, at: 0)
        saveManifest()
        return finalItem
    }

    /// The coordinator supplies a fully downloaded file at a unique, stable inbox
    /// path. Retries reuse its album ID, including after a crash or Photos failure.
    @discardableResult
    func importGen1Original(fileURL: URL, fileName: String, watermark: PhotoWatermarkConfiguration? = nil) async throws -> StoredMediaItem {
        try Task.checkCancellation()
        let id = Gen1MediaStaging.sourceID(for: fileURL)
        if let existing = gen1ImportTasks[id] {
            guard existing.fileName == fileName else { throw Gen1MediaStaging.Failure.sourceChanged }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await existing.task.value
            } onCancel: {
                existing.task.cancel()
            }
        }
        let task = Task { @MainActor in
            try await self.performGen1Import(fileURL: fileURL, fileName: fileName, watermark: watermark)
        }
        gen1ImportTasks[id] = (fileName, task)
        defer { gen1ImportTasks[id] = nil }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performGen1Import(fileURL: URL, fileName: String, watermark: PhotoWatermarkConfiguration?) async throws -> StoredMediaItem {
        try Task.checkCancellation()
        let archive = gen1Archive
        // Large source copies and hashes must not block the UI. Nothing below may
        // remove this verified source, even if decoding or manifest writes fail.
        let archiveTask = Task.detached(priority: .utility) {
            try archive.preserve(fileURL: fileURL, fileName: fileName)
        }
        let receipt = try await withTaskCancellationHandler {
            try await archiveTask.value
        } onCancel: {
            archiveTask.cancel()
        }
        try Task.checkCancellation()
        let source = archive.originalURL(for: receipt)
        try fileManager.createDirectory(at: originalsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)

        if let existing = items.first(where: { $0.id == receipt.id }),
           Self.hasNonemptyFile(originalURL(for: existing)),
           Self.hasNonemptyFile(thumbnailURL(for: existing)) {
            // A previous successful commit must still be readable on disk before
            // treating a retry as successful (and allowing inbox cleanup).
            try commitGen1Item(existing)
            return existing
        }

        let isVideo = Self.isVideoFile(fileName) || fileName.lowercased().hasSuffix(".avi")
        let displayName = isVideo ? (fileName as NSString).deletingPathExtension + ".mp4" : fileName
        let previous = items.first { $0.id == receipt.id }
        var item = StoredMediaItem(
            id: receipt.id, fileName: displayName, isVideo: isVideo,
            createdAt: receipt.createdAt, isFavorite: previous?.isFavorite ?? false, durationSeconds: nil
        )
        let temporary = originalsURL.appendingPathComponent("gen1_\(receipt.id.uuidString)_processing.\(isVideo ? "mp4" : "jpg")")
        let stabilizedURL = originalsURL.appendingPathComponent("gen1_\(receipt.id.uuidString)_eis.mp4")
        let temporaryThumbnail = thumbnailsURL.appendingPathComponent("gen1_\(receipt.id.uuidString)_processing.jpg")
        // These are disposable derivatives only; the verified archive is never a cleanup target.
        try? fileManager.removeItem(at: temporary)
        try? fileManager.removeItem(at: temporaryThumbnail)
        defer {
            try? fileManager.removeItem(at: temporary)
            try? fileManager.removeItem(at: stabilizedURL)
            try? fileManager.removeItem(at: temporaryThumbnail)
        }

        if isVideo {
            await Self.logVideoDuration(url: source, fileName: fileName, stage: "gen1_downloaded_original")
            var originalIsReadable = true
            do {
                try await Gen1VideoOriginalValidator.validateVideoOriginal(source)
            } catch is Gen1VideoOriginalValidator.UnreadableVideoError {
                originalIsReadable = false
            }
            let processing = try await Gen1VideoImportPipeline.process(
                source: source, stabilizedURL: stabilizedURL, output: temporary,
                originalIsReadable: originalIsReadable,
                stabilize: { input, output in
                    let success = await PixSmartVideoEIS.stabilizeGen1Video(from: input, to: output)
                    if success {
                        await Self.logVideoDuration(url: output, fileName: fileName, stage: "gen1_stabilized")
                    }
                    return success
                },
                rotateWithAudio: { video, audio, output in
                    try await Gen1MediaOrientation.rotateVideoClockwise90(from: video, audioFrom: audio, to: output)
                },
                diagnostic: { detail in
                    DebugLogStore.logWiFi("视频防抖回退原件", detail: "file=\(fileName) \(detail)")
                }
            )
            let unreadable = processing == .unreadableOriginal
            let unprocessed = unreadable || processing == .unprocessedOriginal
            DebugLogStore.logWiFi("视频导入处理完成", detail: "file=\(fileName) stabilized=\(processing == .stabilized) rotation=\(unprocessed ? "none" : "clockwise90") playbackUnavailable=\(unreadable) originalPreserved=true")
            if !unreadable {
                await Self.logVideoDuration(url: temporary, fileName: fileName, stage: "gen1_album_final")
            }
            item = StoredMediaItem(
                id: receipt.id, fileName: unprocessed ? fileName : displayName, isVideo: true,
                createdAt: receipt.createdAt, isFavorite: previous?.isFavorite ?? false,
                durationSeconds: unreadable ? nil : Self.videoDuration(url: temporary),
                videoPlaybackUnavailable: unreadable ? true : nil
            )
            if unreadable {
                try Self.generateUnavailableVideoThumbnail(to: temporaryThumbnail)
            } else {
                try Self.generateVideoThumbnail(from: temporary, to: temporaryThumbnail)
            }
        } else {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            let rotated = try Gen1MediaOrientation.rotatePhotoClockwise90(data, fileName: fileName)
            let photo = PhotoWatermarkApplier.applyIfNeeded(rotated, capturedAt: receipt.createdAt, configuration: watermark)
            try photo.write(to: temporary, options: .atomic)
            try Self.generatePhotoThumbnail(from: photo, to: temporaryThumbnail)
            DebugLogStore.logWiFi("Gen1 photo processed", detail: "rotation=clockwise90 watermarkEnabled=\(watermark?.enabled ?? AppSettings.imageWatermarkEnabled) style=\(watermark?.style ?? AppSettings.imageWatermarkStyle) watermarkSource=\(watermark == nil ? "import_settings_fallback" : "capture_snapshot") originalPreserved=true")
        }
        guard Self.hasNonemptyFile(temporary), Self.hasNonemptyFile(temporaryThumbnail) else {
            throw MediaOrientationFixer.Error.encodeFailed
        }
        try Task.checkCancellation()
        let output = originalURL(for: item)
        try installGen1Derivative(from: temporary, to: output)
        try installGen1Derivative(from: temporaryThumbnail, to: thumbnailURL(for: item))
        try commitGen1Item(item)
        print("[MediaLibrary] Gen1 video/photo committed; original preserved; playbackUnavailable=\(item.videoPlaybackUnavailable == true)")
        return item
    }

    private func installGen1Derivative(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private func commitGen1Item(_ item: StoredMediaItem) throws {
        var persisted: [StoredMediaItem] = []
        if fileManager.fileExists(atPath: manifestURL.path) {
            // Do not silently overwrite a corrupt manifest that loadManifest could
            // not read. Failure leaves the source and generated derivatives intact.
            persisted = try JSONDecoder().decode([StoredMediaItem].self, from: Data(contentsOf: manifestURL))
        }
        let memoryIDs = Set(items.map(\.id))
        let combined = items + persisted.filter { !memoryIDs.contains($0.id) }
        let updated = ([item] + combined.filter { $0.id != item.id }).sorted { $0.createdAt > $1.createdAt }
        try Gen1MediaStaging.writeManifest(JSONEncoder().encode(updated), to: manifestURL)
        items = updated
    }

    private static func hasNonemptyFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    func deleteItems(ids: Set<UUID>) {
        items.removeAll { item in
            guard ids.contains(item.id) else { return false }
            try? fileManager.removeItem(at: originalURL(for: item))
            try? fileManager.removeItem(at: thumbnailURL(for: item))
            return true
        }
        saveManifest()
    }

    func toggleFavorite(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFavorite.toggle()
        saveManifest()
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: originalsURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([StoredMediaItem].self, from: data) else {
            items = []
            return
        }
        items = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private static func isVideoFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
    }

    private static func generatePhotoThumbnail(from data: Data, to url: URL) throws {
        guard let image = UIImage(data: data) else { return }
        let thumb = squareCroppedThumbnail(from: image, side: 300)
        guard let jpeg = thumb.jpegData(compressionQuality: 0.85) else { return }
        try jpeg.write(to: url, options: .atomic)
    }

    private static func generateVideoThumbnail(from videoURL: URL, to url: URL) throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        let cgImage: CGImage
        do {
            cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        } catch {
            // A missing preview is not a failed download. Disk-write failures in
            // the placeholder path still propagate and prevent premature cleanup.
            DebugLogStore.logWiFi("视频缩略图不可生成，使用占位图", detail: "file=\(videoURL.lastPathComponent) error=\(error.localizedDescription)")
            try generateUnavailableVideoThumbnail(to: url)
            return
        }
        let image = UIImage(cgImage: cgImage)
        let thumb = squareCroppedThumbnail(from: image, side: 300)
        guard let jpeg = thumb.jpegData(compressionQuality: 0.85) else { return }
        try jpeg.write(to: url, options: .atomic)
    }

    private static func generateUnavailableVideoThumbnail(to url: URL) throws {
        let side: CGFloat = 300
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor(white: 0.90, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let symbol = UIImage(systemName: "video", withConfiguration: UIImage.SymbolConfiguration(pointSize: 64))?
                .withTintColor(UIColor(white: 0.55, alpha: 1), renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 108, y: 118, width: 84, height: 64))
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw MediaOrientationFixer.Error.encodeFailed }
        try jpeg.write(to: url, options: .atomic)
    }

    /// 居中裁剪为正方形缩略图，与 iOS 相册一致。
    private static func squareCroppedThumbnail(from image: UIImage, side: CGFloat) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let scale = max(side / image.size.width, side / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }

    private static func logVideoDuration(url: URL, fileName: String, stage: String) async {
        do {
            let duration = try await AVURLAsset(url: url).load(.duration)
            DebugLogStore.logWiFi("视频时长诊断", detail: "file=\(fileName) stage=\(stage) durationSeconds=\(duration.seconds)")
        } catch {
            DebugLogStore.logWiFi("视频时长读取失败", detail: "file=\(fileName) stage=\(stage) error=\(error.localizedDescription)")
        }
    }

    private static func videoDuration(url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite ? seconds : nil
    }
}

extension StoredMediaItem {
    var durationText: String? {
        guard let durationSeconds else { return nil }
        let total = Int(durationSeconds.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
