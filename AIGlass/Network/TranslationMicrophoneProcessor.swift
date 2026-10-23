@preconcurrency import AVFoundation
import Foundation

/// Tap-thread converter. All mutable converter/diagnostic state is protected by lock.
nonisolated final class TranslationMicrophoneProcessor: @unchecked Sendable {
    let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let lock = NSLock()
    private var statistics = TranslationPCMStatistics()
    private var buffers = 0
    private var conversionErrors = 0
    private var lastPCMAt = ProcessInfo.processInfo.systemUptime

    struct Snapshot {
        let lastPCMAge: TimeInterval
        let detail: String
    }

    init?(inputFormat: AVAudioFormat) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else { return nil }
        self.inputFormat = inputFormat
        self.targetFormat = target
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        buffers += 1
        guard buffer.format.isEqual(inputFormat) else {
            conversionErrors += 1
            return nil
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var supplied = false
        converter.convert(to: output, error: &error) { _, status in
            guard !supplied else { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil else { conversionErrors += 1; return nil }
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
        let pcm = Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        statistics.append(pcm)
        lastPCMAt = ProcessInfo.processInfo.systemUptime
        return pcm
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let age = max(0, ProcessInfo.processInfo.systemUptime - lastPCMAt)
        return Snapshot(lastPCMAge: age, detail: "buffers=\(buffers) conversionErrors=\(conversionErrors) lastPCMAgeMs=\(Int(age * 1_000)) \(statistics.detail)")
    }
}
