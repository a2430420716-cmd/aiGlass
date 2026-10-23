import AVFoundation
import Foundation

struct TranslationMicrophoneTests {
    static func run() {
        // Real resampling, not a model of the converter. No microphone is required.
        for rate in [44_100.0, 48_000.0] {
            for channelCount in [AVAudioChannelCount(1), AVAudioChannelCount(2)] {
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channelCount)!
                let processor = TranslationMicrophoneProcessor(inputFormat: format)!
                let frames = AVAudioFrameCount(rate / 10)
                let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                input.frameLength = frames
                for channel in 0..<Int(channelCount) {
                    for index in 0..<Int(frames) {
                        input.floatChannelData![channel][index] = Float(0.25 * sin(2 * .pi * 440 * Double(index) / rate))
                    }
                }
                var output = Data()
                for _ in 0..<10 {
                    if let pcm = processor.convert(input) { output.append(pcm) }
                }
                var stats = TranslationPCMStatistics()
                stats.append(output)
                precondition(abs(stats.durationMs - 1_000) < 25,
                             "One second at native hardware rate must remain one second at 16 kHz")
                precondition(stats.rms > 100 && stats.peak < 32_768,
                             "Resampling/downmixing must preserve audible PCM16 without clipping")
                precondition(processor.snapshot().detail.contains("conversionErrors=0"))

                let changedFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                let changedBuffer = AVAudioPCMBuffer(pcmFormat: changedFormat, frameCapacity: 160)!
                changedBuffer.frameLength = 160
                precondition(processor.convert(changedBuffer) == nil,
                             "Never submit a changed hardware format to the old converter")
                precondition(processor.snapshot().detail.contains("conversionErrors=1"))

                let replacement = TranslationMicrophoneProcessor(inputFormat: changedFormat)!
                changedBuffer.floatChannelData![0].initialize(repeating: 0, count: 160)
                precondition(replacement.convert(changedBuffer)?.count == 320,
                             "A rebuilt converter resumes PCM after a route format change")
            }
        }
        print("Translation microphone resampling and format-change tests passed")
    }
}

