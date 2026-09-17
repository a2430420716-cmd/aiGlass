import AVFoundation
import UIKit

enum MediaOrientationFixer {
    enum Error: Swift.Error {
        case invalidImage
        case encodeFailed
        case missingVideoTrack
        case compositionFailed
        case exportFailed
    }

    static func rotateImageDataCounterClockwise90(_ data: Data, fileName: String) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw Error.invalidImage
        }
        let rotated = rotateImageCounterClockwise90(image)
        let lower = fileName.lowercased()
        if lower.hasSuffix(".png"), let png = rotated.pngData() {
            return png
        }
        guard let jpeg = rotated.jpegData(compressionQuality: 0.92) else {
            throw Error.encodeFailed
        }
        return jpeg
    }

    /// 逆时针旋转视频 90°。
    /// 采用 passthrough（直通）导出，仅把旋转写入视频轨道的 preferredTransform，
    /// 不做解码/重编码，规避眼镜非标准 mp4 在完整转码管线里的 "Cannot Decode" 问题。
    static func rotateVideoCounterClockwise90(from inputURL: URL, to outputURL: URL) async throws {
        try await rotateVideoCounterClockwise90(
            from: inputURL,
            audioFrom: inputURL,
            to: outputURL
        )
    }

    /// 使用处理后视频轨，并从原视频补回音轨，再写入逆时针 90° 方向。
    static func rotateVideoCounterClockwise90(
        from videoURL: URL,
        audioFrom audioURL: URL,
        to outputURL: URL
    ) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        guard let assetVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw Error.missingVideoTrack
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw Error.compositionFailed
        }

        let duration = try await videoAsset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try videoTrack.insertTimeRange(timeRange, of: assetVideoTrack, at: .zero)

        let audioAsset = AVURLAsset(url: audioURL)
        if let assetAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioDuration = try await audioAsset.load(.duration)
            let copiedDuration = CMTimeCompare(audioDuration, duration) < 0 ? audioDuration : duration
            try audioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: copiedDuration),
                of: assetAudioTrack,
                at: .zero
            )
        }

        let naturalSize = try await assetVideoTrack.load(.naturalSize)
        let sourceTransform = try await assetVideoTrack.load(.preferredTransform)

        // 逆时针 90°：旋转 -90° 后沿 y 平移原始宽度，使内容落在正坐标区间。
        let rotateCCW = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: naturalSize.width)
        videoTrack.preferredTransform = sourceTransform.concatenating(rotateCCW)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw Error.exportFailed
        }

        try await exportSession.export(to: outputURL, as: .mp4)
    }

    private static func rotateImageCounterClockwise90(_ image: UIImage) -> UIImage {
        let size = image.size
        let newSize = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { context in
            context.cgContext.translateBy(x: 0, y: newSize.height)
            context.cgContext.rotate(by: -.pi / 2)
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
