import AVFoundation
import Foundation

/// The service sends signed 16-bit little-endian mono PCM at 16 kHz.
/// AVAudioPlayerNode connects to the mixer with noninterleaved Float32 PCM.
enum TranslationPCMPlayback {
    static func makeFormat() -> AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
    }

    static func makeBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !data.isEmpty, data.count.isMultiple(of: 2),
              data.count / 2 <= Int(UInt32.max),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              format.channelCount == 1, format.sampleRate == 16_000 else { return nil }
        let frames = AVAudioFrameCount(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let output = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in 0..<Int(frames) {
                // Byte reads also handle Data whose storage is not Int16-aligned.
                let bits = UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8)
                output[index] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        return buffer
    }
}
