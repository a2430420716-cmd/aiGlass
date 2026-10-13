import Combine
import Foundation

/// Persists first-generation live PCM directly to the per-user recording library.
/// Audio stays on disk while recording, avoiding unbounded memory growth.
@MainActor
final class Gen1AiRecordingManager: ObservableObject {
    static let shared = Gen1AiRecordingManager()

    @Published private(set) var isRecording = false
    @Published private(set) var lastError: String?
    private var output: FileHandle?
    private var fileURL: URL?
    private var pcmBytes: UInt64 = 0

    private init() {}

    @discardableResult
    func start() -> Bool {
        guard output == nil else { return true }
        lastError = nil
        do {
            let directory = AIRecordingStore.shared.recordingsDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
            let name = "record_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(8)).wav"
            let url = directory.appendingPathComponent(name)
            fileURL = url
            try Gen1PCM.wavHeader(pcmBytes: 0).write(to: url, options: .atomic)
            output = try FileHandle(forWritingTo: url)
            try output?.seekToEnd()
            pcmBytes = 0
            isRecording = true
            return true
        } catch {
            fail(error)
            return false
        }
    }

    @discardableResult
    func appendPCM(_ payload: Data) -> Bool {
        guard let output else { return false }
        guard !payload.isEmpty else { return true }
        do {
            guard UInt64(payload.count) <= UInt64(UInt32.max) - 36 - pcmBytes else {
                throw NSError(domain: "Gen1Recording", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    L10n.t("录音已达到 WAV 文件大小上限", "Recording reached the WAV file size limit")])
            }
            try output.write(contentsOf: payload)
            pcmBytes += UInt64(payload.count)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    @discardableResult
    func stop() -> AIRecordingItem? {
        guard let output, let url = fileURL else { return nil }
        // A truncated final BLE sample must not leave an invalid PCM16 file.
        let alignedBytes = pcmBytes & ~UInt64(1)
        guard alignedBytes > 0 else { clear(deleteFile: true); return nil }
        do {
            try output.truncate(atOffset: alignedBytes + 44)
            try output.seek(toOffset: 0)
            try output.write(contentsOf: Gen1PCM.wavHeader(pcmBytes: UInt32(alignedBytes)))
            try output.synchronize()
            try output.close()
            self.output = nil
            fileURL = nil
            pcmBytes = 0
            isRecording = false
            return AIRecordingStore.shared.addRecording(
                fileURL: url, fileName: url.lastPathComponent,
                durationMs: Int64(alignedBytes * 1000 / UInt64(Gen1PCM.bytesPerSecond)), playable: true
            )
        } catch {
            fail(error)
            return nil
        }
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        print("[Gen1Recording] \(error.localizedDescription)")
        clear(deleteFile: true)
    }

    private func clear(deleteFile: Bool) {
        try? output?.close()
        if deleteFile, let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        output = nil
        fileURL = nil
        pcmBytes = 0
        isRecording = false
    }
}
