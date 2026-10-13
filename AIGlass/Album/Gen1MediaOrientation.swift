import AVFoundation
import UIKit

/// Gen1 has the opposite orientation to Gen2. Rotation follows stabilization;
/// use original audio because the native stabilization writer outputs video only.
@MainActor
enum Gen1MediaOrientation {
    static func rotatePhotoClockwise90(_ data: Data, fileName: String) throws -> Data {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw MediaOrientationFixer.Error.invalidImage
        }
        let size = image.size
        let outputSize = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let imageResult = UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            context.cgContext.translateBy(x: outputSize.width, y: 0)
            context.cgContext.rotate(by: .pi / 2)
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        if fileName.lowercased().hasSuffix(".png"), let png = imageResult.pngData() { return png }
        guard let jpeg = imageResult.jpegData(compressionQuality: 0.92) else {
            throw MediaOrientationFixer.Error.encodeFailed
        }
        return jpeg
    }

    /// Passthrough retains original video samples and every audio track. Normalize
    /// an existing track transform before applying the Gen1 clockwise rotation.
    static func rotateVideoClockwise90(from inputURL: URL, to outputURL: URL) async throws {
        try await rotateVideoClockwise90(from: inputURL, audioFrom: inputURL, to: outputURL)
    }

    static func rotateVideoClockwise90(from inputURL: URL, audioFrom audioURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaOrientationFixer.Error.missingVideoTrack
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaOrientationFixer.Error.compositionFailed
        }
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        let audioAsset = AVURLAsset(url: audioURL)
        for sourceAudio in try await audioAsset.loadTracks(withMediaType: .audio) {
            guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MediaOrientationFixer.Error.compositionFailed
            }
            let audioRange = try await sourceAudio.load(.timeRange)
            let copiedRange = CMTimeRangeGetIntersection(range, otherRange: audioRange)
            if copiedRange.duration > .zero {
                try audio.insertTimeRange(copiedRange, of: sourceAudio, at: copiedRange.start)
            }
        }
        let naturalSize = try await sourceVideo.load(.naturalSize)
        let transform = try await sourceVideo.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let normalized = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let clockwise = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: bounds.height, ty: 0)
        video.preferredTransform = normalized.concatenating(clockwise)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaOrientationFixer.Error.exportFailed
        }
        try await exporter.export(to: outputURL, as: .mp4)
    }
}
