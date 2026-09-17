import AVFoundation
import AudioToolbox
import Foundation

/// Align Android `AiVoiceM4aConverter`: Opus frames → PCM → AAC/M4A.
enum AIVoiceM4aConverter {
    enum ConverterError: LocalizedError {
        case emptyFrames
        case decoderUnavailable
        case decodeFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .emptyFrames: return L10n.t("未收到有效语音数据", "No valid voice data received")
            case .decoderUnavailable: return L10n.t("语音解码器不可用", "Voice decoder unavailable")
            case .decodeFailed: return L10n.t("语音解码失败", "Voice decode failed")
            case .encodeFailed: return L10n.t("语音封装失败", "Voice encode failed")
            }
        }
    }

    private static let sampleRate = 16_000
    private static let channels = 1
    private static let opusFrameSamples = 320 // 20ms @ 16kHz，对齐 Android

    static func convertOpusFramesToM4A(_ frames: [Data]) throws -> Data {
        guard !frames.isEmpty else { throw ConverterError.emptyFrames }
        let sampleLens = frames.prefix(12).map(\.count)
        let firstHex = frames.first?.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ") ?? ""
        print("[AIVoiceM4A] opus frames=\(frames.count) sampleLens=\(sampleLens) first=\(firstHex)")

        let pcm = try decodeOpusFramesToPCM(frames)
        guard !pcm.isEmpty else { throw ConverterError.decodeFailed }
        print("[AIVoiceM4A] pcm bytes=\(pcm.count) durationMs≈\((pcm.count / 2) * 1000 / sampleRate)")

        let m4a = try encodePCMToM4A(pcm)
        guard m4a.count > 100, isLikelyMPEG4(m4a) else {
            print("[AIVoiceM4A] invalid m4a output bytes=\(m4a.count)")
            throw ConverterError.encodeFailed
        }
        print("[AIVoiceM4A] m4a bytes=\(m4a.count)")
        return m4a
    }

    static func decodeOpusFramesToPCM(_ frames: [Data]) throws -> Data {
        let decoder: AIGlassOpusDecoder
        do {
            decoder = try AIGlassOpusDecoder(
                sampleRate: Int32(sampleRate),
                channels: Int32(channels)
            )
        } catch {
            throw ConverterError.decoderUnavailable
        }

        var pcm = Data()
        pcm.reserveCapacity(frames.count * opusFrameSamples * channels * 2)
        var ok = 0
        for (index, frame) in frames.enumerated() {
            do {
                let chunk = try decoder.decodeFrame(frame)
                if !chunk.isEmpty {
                    pcm.append(chunk)
                    ok += 1
                }
            } catch {
                print("[AIVoiceM4A] skip bad frame index=\(index) err=\(error.localizedDescription)")
            }
        }
        print("[AIVoiceM4A] decoded ok=\(ok)/\(frames.count)")
        guard ok > 0 else { throw ConverterError.decodeFailed }
        return pcm
    }

    /// ExtAudioFile 写 AAC/M4A。**必须先 Dispose 再读盘**，否则半截文件 → OSStatus 1685348671 (dta?)。
    private static func encodePCMToM4A(_ pcm: Data) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai_voice_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try? FileManager.default.removeItem(at: tempURL)

        var destinationFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var audioFile: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            tempURL as CFURL,
            kAudioFileM4AType,
            &destinationFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &audioFile
        )
        guard status == noErr, let audioFile else {
            print("[AIVoiceM4A] ExtAudioFileCreate failed status=\(status)")
            throw ConverterError.encodeFailed
        }

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        status = ExtAudioFileSetProperty(
            audioFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard status == noErr else {
            print("[AIVoiceM4A] set client format failed status=\(status)")
            ExtAudioFileDispose(audioFile)
            throw ConverterError.encodeFailed
        }

        let frameCount = UInt32(pcm.count / (2 * channels))
        guard frameCount > 0 else {
            ExtAudioFileDispose(audioFile)
            throw ConverterError.encodeFailed
        }

        status = pcm.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kAudio_ParamError }
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(pcm.count),
                    mData: UnsafeMutableRawPointer(mutating: base)
                )
            )
            return ExtAudioFileWrite(audioFile, frameCount, &bufferList)
        }
        guard status == noErr else {
            print("[AIVoiceM4A] ExtAudioFileWrite failed status=\(status)")
            ExtAudioFileDispose(audioFile)
            throw ConverterError.encodeFailed
        }

        // 关文件，flush moov/mdat —— 此前 bug：边开边读 → 不可播。
        status = ExtAudioFileDispose(audioFile)
        guard status == noErr else {
            print("[AIVoiceM4A] ExtAudioFileDispose failed status=\(status)")
            throw ConverterError.encodeFailed
        }

        let data = try Data(contentsOf: tempURL)
        do {
            _ = try AVAudioFile(forReading: tempURL)
        } catch {
            print("[AIVoiceM4A] AVAudioFile open failed: \(error.localizedDescription)")
            throw ConverterError.encodeFailed
        }
        return data
    }

    private static func isLikelyMPEG4(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let type = data.subdata(in: 4..<8)
        return String(data: type, encoding: .ascii) == "ftyp"
    }
}
