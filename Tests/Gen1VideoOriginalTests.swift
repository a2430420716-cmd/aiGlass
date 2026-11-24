import AVFoundation
import CoreVideo
import Foundation

// Test-only app services. The production validator and AVFoundation run unchanged.
enum L10n {
    nonisolated static func t(_ zh: String, _ en: String) -> String { zh }
}
enum DebugLogStore {
    static func logWiFi(_ message: String, detail: String) {}
}

@main
struct Gen1VideoOriginalTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let invalid = root.appendingPathComponent("interrupted.mp4")
        let bytes = Data("ftyp incomplete camera recording without usable tracks".utf8)
        try bytes.write(to: invalid)
        do {
            try await Gen1VideoOriginalValidator.validateVideoOriginal(invalid)
            preconditionFailure("Undecodable recording accepted")
        } catch let error as Gen1VideoOriginalValidator.UnreadableVideoError {
            precondition(!error.detail.isEmpty, "Underlying diagnostic retained")
            precondition(error.localizedDescription.contains("原件已保留"), "Error explains original retention")
        }
        let retainedInvalid = try Data(contentsOf: invalid)
        precondition(retainedInvalid == bytes, "Validation cannot modify invalid originals")

        let valid = root.appendingPathComponent("normal.mp4")
        let writer = try AVAssetWriter(outputURL: valid, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 48
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48
        ])
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        for frame in 0..<3 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(input.isReadyForMoreMediaData)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let validBytes = try Data(contentsOf: valid)
        try await Gen1VideoOriginalValidator.validateVideoOriginal(valid)
        let retainedValid = try Data(contentsOf: valid)
        precondition(retainedValid == validBytes, "Normal video validation is read only")

        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await Gen1VideoOriginalValidator.validateVideoOriginal(valid)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancellationPreserved = await cancelled.value
        precondition(cancellationPreserved, "Cancellation must not be reported as corrupt video")
        print("Gen1 original validation: unreadable, normal, source retention and cancellation passed")
    }
}
