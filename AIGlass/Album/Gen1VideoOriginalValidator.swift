import AVFoundation
import Foundation

/// Detect unreadable originals before attempting enhancement. Original bytes stay untouched.
@MainActor
enum Gen1VideoOriginalValidator {
    private enum MetadataError: Error { case invalidVideo }

    struct UnreadableVideoError: LocalizedError {
        let detail: String

        nonisolated var errorDescription: String? {
            L10n.t(
                "原始视频无法读取，可能因录制中断未完整保存。原件已保留在手机，可继续导入其他文件。",
                "The original video cannot be read and may be incomplete after interrupted recording. It is retained on this phone. You can still import other files."
            )
        }
    }

    /// A complete TCP download does not prove the MP4 was finalized by the camera.
    static func validateVideoOriginal(_ url: URL) async throws {
        try Task.checkCancellation()
        do {
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw MetadataError.invalidVideo
            }
            let duration = try await asset.load(.duration).seconds
            let size = try await video.load(.naturalSize)
            guard duration.isFinite, duration > 0,
                  size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else {
                throw MetadataError.invalidVideo
            }
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            let underlying = error as NSError
            let detail = "domain=\(underlying.domain) code=\(underlying.code) error=\(underlying.localizedDescription)"
            DebugLogStore.logWiFi("原始视频不可读取，保留原件并跳过防抖", detail: "file=\(url.lastPathComponent) \(detail)")
            throw UnreadableVideoError(detail: detail)
        }
    }

}
