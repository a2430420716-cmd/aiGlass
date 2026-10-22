import AVFoundation
import Foundation

@main
struct TranslationPCMPlaybackTests {
    static func main() throws {
        let format = TranslationPCMPlayback.makeFormat()!
        precondition(format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved)
        precondition(format.sampleRate == 24_000 && format.channelCount == 1)
        let oneSecond = TranslationPCMPlayback.makeBuffer(from: Data(repeating: 0, count: 48_000), format: format)!
        precondition(Double(oneSecond.frameLength) / format.sampleRate == 1,
                     "Backend TTS is 24 kHz; 48,000 PCM16 bytes must play for one second")
        let data = Data([0x00, 0x80, 0xFF, 0xFF, 0x00, 0x00, 0x01, 0x00, 0xFF, 0x7F])
        let buffer = TranslationPCMPlayback.makeBuffer(from: data, format: format)!
        precondition(buffer.frameLength == 5)
        let values = buffer.floatChannelData![0]
        let expected: [Float] = [-1, -1 / 32_768, 0, 1 / 32_768, 32_767 / 32_768]
        for index in expected.indices { precondition(values[index] == expected[index]) }
        precondition(TranslationPCMPlayback.makeBuffer(from: Data(), format: format) == nil)
        precondition(TranslationPCMPlayback.makeBuffer(from: Data([0]), format: format) == nil)
        let integerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: true)!
        precondition(TranslationPCMPlayback.makeBuffer(from: data, format: integerFormat) == nil)
        let inputRateFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        precondition(TranslationPCMPlayback.makeBuffer(from: data, format: inputRateFormat) == nil,
                     "Do not reuse the 16 kHz capture format for playback")

        // Exercise the connection that raised SetOutputFormat in Build 155,
        // without requiring a microphone, Bluetooth device, or network service.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(buffer)
        player.play()
        let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 5)!
        let status = try engine.renderOffline(5, to: rendered)
        precondition(status == .success && rendered.frameLength == 5)
        print("Translation PCM conversion and offline player connection passed")
    }
}
