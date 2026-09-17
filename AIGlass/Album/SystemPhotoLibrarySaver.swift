import Foundation
import Photos

enum SystemPhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case permissionDenied
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return L10n.t("未获得添加到系统相册的权限", "No permission to add to Photos")
            case .saveFailed:
                return L10n.t("保存到系统相册失败", "Failed to save to Photos")
            }
        }
    }

    static var canAddAssets: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return status == .authorized || status == .limited
    }

    static func requestAddAuthorization() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited {
            return true
        }
        guard current == .notDetermined else { return false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// 保存 App 内已处理完成的最终媒体文件。
    static func save(fileURL: URL, isVideo: Bool) async throws {
        guard canAddAssets else { throw SaveError.permissionDenied }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SaveError.saveFailed
        }

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                }
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: error ?? SaveError.saveFailed
                    )
                }
            }
        }
    }
}
