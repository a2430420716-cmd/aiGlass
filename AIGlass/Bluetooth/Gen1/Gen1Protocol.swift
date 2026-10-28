import Foundation

/// Generation is confirmed by GATT services; the advertised name is only a scan-time hint.
enum DeviceGeneration: String, Codable, Sendable {
    case unknown, gen1G5K61, gen2

    static func fromDeviceName(_ name: String?) -> DeviceGeneration {
        let normalized = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.hasPrefix("L1 ") || normalized.contains("G5K6") ? .gen1G5K61 : .unknown
    }
}

struct DeviceCapabilities: Equatable, Sendable {
    let photo: Bool
    let video: Bool
    let recordDuration: Bool
    let recordDurationSeconds: [Int]
    let videoResolution: Bool
    let eq: Bool
    let wearingDetection: Bool
    let voiceWakeupSetting: Bool
    let aiVoice: Bool
    let aiRecording: Bool
    let aiImageRecognition: Bool
    let translation: Bool
    let mediaImport: Bool
    let firmwareUpgrade: Bool
    let bluetoothUpgrade: Bool
    let tutorial: Bool

    static let allRecordDurationSeconds = [15, 60, 180, 300, 600]
    static let unknown = forGeneration(.unknown)
    static let gen1 = forGeneration(.gen1G5K61)
    static let gen2 = forGeneration(.gen2)

    static func forGeneration(_ generation: DeviceGeneration) -> DeviceCapabilities {
        let known = generation != .unknown
        return DeviceCapabilities(
            photo: known, video: known, recordDuration: known,
            recordDurationSeconds: allRecordDurationSeconds,
            videoResolution: generation == .gen2, eq: known, wearingDetection: known,
            voiceWakeupSetting: generation == .gen2, aiVoice: known, aiRecording: known,
            aiImageRecognition: known, translation: known, mediaImport: known,
            firmwareUpgrade: known, bluetoothUpgrade: known, tutorial: known
        )
    }
}

/// G5K61 service, write, control notification and AE3D v2 audio notification UUIDs.
enum Gen1BleProtocol {
    static let serviceUUIDString = "AE3A"
    static let writeCharacteristicUUIDString = "AE3B"
    static let notifyCharacteristicUUIDString = "AE3C"
    static let voiceCharacteristicUUIDString = "AE3D"
}

/// Values mirror Android Gen1Protocol.kt, including command aliases used by firmware.
enum Gen1Commands {
    static let aiVoice: UInt8 = 0x01
    static let pcmAudio: UInt8 = 0x02
    static let syncTime: UInt8 = 0x04
    static let battery: UInt8 = 0x05
    static let wifiProvision: UInt8 = 0x06
    static let newFileCount: UInt8 = 0x07
    static let factoryReset: UInt8 = 0x08
    static let firmwareOTA: UInt8 = 0x09
    static let restart: UInt8 = 0x12
    static let bluetoothVersion: UInt8 = 0x14
    static let firmwareVersion: UInt8 = 0x15
    static let wifiConfig: UInt8 = 0x17
    static let bleMac: UInt8 = 0x21
    static let wearingState: UInt8 = 0x24
    static let recordDurationSet: UInt8 = 0x25
    static let prepareP2P: UInt8 = 0x29
    static let networkStatus: UInt8 = 0x32
    static let fileList: UInt8 = 0x33
    static let snAuth: UInt8 = 0x36
    static let openHotspot: UInt8 = 0x37
    static let aiRecord = openHotspot
    static let closeHotspot: UInt8 = 0x38
    /// Current 3303 firmware reports progress here; older firmware uses 0x18.
    static let firmwareOTAProgress: UInt8 = 0x3A
    static let firmwareOTAProgressLegacy: UInt8 = 0x18
    static let photoRecognize: UInt8 = 0x44
    static let storage: UInt8 = 0x45
    static let takePhoto: UInt8 = 0x60
    static let startVideo: UInt8 = 0x61
    static let stopVideo: UInt8 = 0x62
    static let deviceName: UInt8 = 0x63
    static let deviceType: UInt8 = 0x64
    static let systemName: UInt8 = 0x65
    static let volumeChanged: UInt8 = 0x67
    static let batteryChanged: UInt8 = 0x68
    static let voiceWakeup: UInt8 = 0x69
    static let mediaPlay: UInt8 = 0x6A
    static let mediaPause: UInt8 = 0x6B
    static let mediaNext: UInt8 = 0x6C
    static let mediaPrevious: UInt8 = 0x6D
    static let aiVoiceStatus: UInt8 = 0x6E
    static let aiImage: UInt8 = 0x70
    static let imageResolutionSet: UInt8 = 0x71
    static let deviceStatusQuery: UInt8 = 0x72
    static let deviceStatusChanged: UInt8 = 0x73
    static let masterReset: UInt8 = 0x74
    static let tutorial: UInt8 = 0x81
    static let eqSet: UInt8 = 0x82
    static let eqQuery: UInt8 = 0x83
    static let wearingSet: UInt8 = 0x84
    static let wearingQuery: UInt8 = 0x85
    static let recordDurationQuery: UInt8 = 0x87
    static let translateRecord: UInt8 = 0x90
    static let busy: UInt8 = 0xE3
}

enum Gen1ProtocolError: Error, Equatable {
    case payloadTooLarge
    case invalidImageSequence
    case invalidRetransmitCount
    case unsupportedRecordDuration
}

struct Gen1ControlFrame: Equatable, Sendable {
    let sender: UInt8
    let receiver: UInt8
    let command: UInt8
    let payload: Data
    let raw: Data
    var isBusy: Bool { payload.first == Gen1Commands.busy }
}

enum Gen1ControlCodec {
    static let sof: UInt8 = 0xAA
    static let app: UInt8 = 0x02
    static let device: UInt8 = 0x03
    static let headerSize = 6
    static let crcSize = 2
    static let maxPayloadSize = 16 * 1024

    static func buildCommand(command: UInt8, payload: Data = Data()) throws -> Data {
        guard payload.count <= maxPayloadSize else { throw Gen1ProtocolError.payloadTooLarge }
        var bytes = Data([sof, app, device, command, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        bytes.append(payload)
        let crc = crc16Modbus(bytes)
        bytes.append(contentsOf: [UInt8(crc & 0xFF), UInt8(crc >> 8)])
        return bytes
    }

    static func parse(_ frame: Data) -> Gen1ControlFrame? {
        let bytes = [UInt8](frame)
        guard bytes.count >= headerSize + crcSize, bytes[0] == sof else { return nil }
        let size = Int(bytes[4]) << 8 | Int(bytes[5])
        guard size <= maxPayloadSize, bytes.count == headerSize + size + crcSize else { return nil }
        let crc = UInt16(bytes[bytes.count - 2]) | UInt16(bytes[bytes.count - 1]) << 8
        guard crc16Modbus(bytes.dropLast(crcSize)) == crc else { return nil }
        return Gen1ControlFrame(sender: bytes[1], receiver: bytes[2], command: bytes[3],
                                payload: Data(bytes[headerSize..<(headerSize + size)]), raw: Data(bytes))
    }

    static func crc16Modbus<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }
}

/// Per-notification framing diagnostics contain counts only, never control payloads.
struct Gen1ControlDecodeResult: Sendable {
    let frames: [Gen1ControlFrame]
    let inputBytes: Int
    let bufferedBytesBefore: Int
    let bufferedBytes: Int
    let expectedFrameBytes: Int?
    /// Includes non-SOF bytes skipped while resynchronizing after a rejected candidate.
    let noiseDiscardedBytes: Int
    let crcFailures: Int
    let oversizedLengthDiscards: Int
    let overflowDiscardedBytes: Int

    var diagnosticSummary: String {
        let waiting = bufferedBytes == 0 ? "none" : (expectedFrameBytes == nil ? "header" : "frame")
        let expected = expectedFrameBytes.map(String.init) ?? (bufferedBytes == 0 ? "none" : "unknown")
        return "inputBytes=\(inputBytes) bufferedBefore=\(bufferedBytesBefore) decodedFrames=\(frames.count) " +
            "bufferedBytes=\(bufferedBytes) expectedFrameBytes=\(expected) waiting=\(waiting) " +
            "noiseDiscardedBytes=\(noiseDiscardedBytes) crcFailures=\(crcFailures) " +
            "oversizedLengthDiscards=\(oversizedLengthDiscards) overflowDiscardedBytes=\(overflowDiscardedBytes)"
    }
}

final class Gen1ControlStreamDecoder {
    private var buffer: [UInt8] = []
    private let lock = NSLock()

    func append(_ bytes: Data) -> [Gen1ControlFrame] {
        appendWithDiagnostics(bytes).frames
    }

    func appendWithDiagnostics(_ bytes: Data) -> Gen1ControlDecodeResult {
        lock.lock(); defer { lock.unlock() }
        let bufferedBytesBefore = buffer.count
        var noiseDiscardedBytes = 0
        var crcFailures = 0
        var oversizedLengthDiscards = 0
        var overflowDiscardedBytes = 0
        var frames: [Gen1ControlFrame] = []

        func result() -> Gen1ControlDecodeResult {
            let expectedFrameBytes: Int? = buffer.count >= Gen1ControlCodec.headerSize
                ? Gen1ControlCodec.headerSize + (Int(buffer[4]) << 8 | Int(buffer[5])) + Gen1ControlCodec.crcSize
                : nil
            return Gen1ControlDecodeResult(
                frames: frames, inputBytes: bytes.count, bufferedBytesBefore: bufferedBytesBefore,
                bufferedBytes: buffer.count, expectedFrameBytes: expectedFrameBytes,
                noiseDiscardedBytes: noiseDiscardedBytes, crcFailures: crcFailures,
                oversizedLengthDiscards: oversizedLengthDiscards, overflowDiscardedBytes: overflowDiscardedBytes
            )
        }

        guard !bytes.isEmpty else { return result() }
        buffer.append(contentsOf: bytes)
        var cursor = 0
        while cursor < buffer.count {
            guard buffer[cursor] == Gen1ControlCodec.sof else {
                noiseDiscardedBytes += 1
                cursor += 1
                continue
            }
            guard buffer.count - cursor >= Gen1ControlCodec.headerSize else { break }
            let size = Int(buffer[cursor + 4]) << 8 | Int(buffer[cursor + 5])
            guard size <= Gen1ControlCodec.maxPayloadSize else {
                oversizedLengthDiscards += 1
                cursor += 1
                continue
            }
            let frameSize = Gen1ControlCodec.headerSize + size + Gen1ControlCodec.crcSize
            guard buffer.count - cursor >= frameSize else { break }
            if let frame = Gen1ControlCodec.parse(Data(buffer[cursor..<(cursor + frameSize)])) {
                frames.append(frame)
                cursor += frameSize
            } else {
                crcFailures += 1
                cursor += 1
            }
        }
        buffer = Array(buffer.dropFirst(cursor))
        if buffer.count > Gen1ControlCodec.maxPayloadSize + 8 {
            overflowDiscardedBytes = buffer.count
            buffer.removeAll()
        }
        return result()
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
    }
}

enum Gen1VoiceFrameType: UInt8, Sendable { case start = 0, data = 1, end = 2 }

struct Gen1VoiceFrame: Equatable, Sendable {
    let type: Gen1VoiceFrameType
    let flags: UInt8
    let sequence: Int
    let payload: Data
}

struct Gen1VoiceDrop: Equatable, Sendable {
    let reason: String
    var sequence: Int? = nil
    var frameCrc: UInt16? = nil
    var calculatedCrc: UInt16? = nil
}

enum Gen1VoiceParseResult: Equatable, Sendable {
    case parsed(Gen1VoiceFrame)
    case dropped(Gen1VoiceDrop)
}

enum Gen1VoiceStreamEvent: Equatable, Sendable {
    case frame(Gen1VoiceFrame, raw: Data)
    case dropped(Gen1VoiceDrop)
    case buffered(bufferedBytes: Int, expectedFrameBytes: Int?)
}

/// AE3D v2: A5 02, type, flags, sequence BE, length LE, CRC LE, Opus payload.
/// CRC covers the eight-byte header followed by payload, excluding the CRC field.
final class Gen1VoiceStreamDecoder {
    static let maxPayloadSize = 4096
    private var buffer: [UInt8] = []
    private let lock = NSLock()

    func parseNotification(_ data: Data) -> Gen1VoiceParseResult {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { return .dropped(.init(reason: "frame too short: \(bytes.count)")) }
        guard bytes[0] == 0xA5, bytes[1] == 2 else { return .dropped(.init(reason: "invalid magic/version")) }
        let sequence = Int(bytes[4]) << 8 | Int(bytes[5])
        let size = Int(bytes[6]) | Int(bytes[7]) << 8
        guard size <= Self.maxPayloadSize, 10 + size <= bytes.count else {
            return .dropped(.init(reason: "invalid payload length: declared=\(size) actual=\(bytes.count - 10)", sequence: sequence))
        }
        let frameCrc = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
        let crc = Gen1ControlCodec.crc16Modbus(Array(bytes[0..<8]) + bytes[10..<(10 + size)])
        guard crc == frameCrc else {
            return .dropped(.init(reason: "CRC mismatch", sequence: sequence, frameCrc: frameCrc, calculatedCrc: crc))
        }
        guard let type = Gen1VoiceFrameType(rawValue: bytes[2]) else {
            return .dropped(.init(reason: "unknown type: \(bytes[2])", sequence: sequence))
        }
        guard type != .data || size != 0 else { return .dropped(.init(reason: "empty DATA payload", sequence: sequence)) }
        return .parsed(Gen1VoiceFrame(type: type, flags: bytes[3], sequence: sequence, payload: Data(bytes[10..<(10 + size)])))
    }

    func appendEvents(_ bytes: Data) -> [Gen1VoiceStreamEvent] {
        lock.lock(); defer { lock.unlock() }
        guard !bytes.isEmpty else { return [] }
        buffer.append(contentsOf: bytes)
        var events: [Gen1VoiceStreamEvent] = []
        var cursor = 0
        while cursor < buffer.count {
            let searchStart = cursor
            while cursor + 1 < buffer.count, !(buffer[cursor] == 0xA5 && buffer[cursor + 1] == 2) { cursor += 1 }
            if cursor + 1 >= buffer.count {
                if buffer[cursor] != 0xA5 { cursor += 1 }
                if cursor > searchStart { events.append(.dropped(.init(reason: "resync discarded \(cursor - searchStart) byte(s)"))) }
                break
            }
            if cursor > searchStart { events.append(.dropped(.init(reason: "resync discarded \(cursor - searchStart) byte(s)"))) }
            let remaining = buffer.count - cursor
            guard remaining >= 10 else { events.append(.buffered(bufferedBytes: remaining, expectedFrameBytes: nil)); break }
            let sequence = Int(buffer[cursor + 4]) << 8 | Int(buffer[cursor + 5])
            let size = Int(buffer[cursor + 6]) | Int(buffer[cursor + 7]) << 8
            guard size <= Self.maxPayloadSize else {
                events.append(.dropped(.init(reason: "invalid payload length: declared=\(size)", sequence: sequence)))
                cursor += 1
                continue
            }
            let frameSize = 10 + size
            guard remaining >= frameSize else {
                events.append(.buffered(bufferedBytes: remaining, expectedFrameBytes: frameSize))
                break
            }
            let raw = Data(buffer[cursor..<(cursor + frameSize)])
            switch parseNotification(raw) {
            case .parsed(let frame):
                events.append(.frame(frame, raw: raw))
                cursor += frameSize
            case .dropped(let drop):
                events.append(.dropped(drop))
                // Search within the rejected candidate too, recovering from a damaged length.
                cursor += 1
            }
        }
        buffer = Array(buffer.dropFirst(cursor))
        if buffer.count > Self.maxPayloadSize + 10 {
            events.append(.dropped(.init(reason: "stream buffer overflow: \(buffer.count)")))
            buffer.removeAll()
        }
        return events
    }

    func append(_ bytes: Data) -> [Gen1VoiceFrame] {
        appendEvents(bytes).compactMap { if case .frame(let frame, _) = $0 { return frame }; return nil }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
    }
}

enum Gen1VoiceSequenceResult: Equatable, Sendable {
    case accepted
    case gap(expected: Int, actual: Int, missing: Int)
    case duplicateOrLate(expected: Int, actual: Int)
}

final class Gen1VoiceSequenceTracker {
    private var expectedSequence: Int?
    private let lock = NSLock()

    func onFrame(_ frame: Gen1VoiceFrame) -> Gen1VoiceSequenceResult {
        lock.lock(); defer { lock.unlock() }
        if frame.type == .start { expectedSequence = (frame.sequence + 1) & 0xFFFF; return .accepted }
        if frame.type == .end { expectedSequence = nil; return .accepted }
        guard let expected = expectedSequence else {
            expectedSequence = (frame.sequence + 1) & 0xFFFF
            return .accepted
        }
        let distance = (frame.sequence - expected) & 0xFFFF
        guard distance < 0x8000 else { return .duplicateOrLate(expected: expected, actual: frame.sequence) }
        expectedSequence = (frame.sequence + 1) & 0xFFFF
        return distance == 0 ? .accepted : .gap(expected: expected, actual: frame.sequence, missing: distance)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        expectedSequence = nil
    }
}

enum Gen1Payloads {
    static func syncTime(epochSeconds: Int64 = Int64(Date().timeIntervalSince1970)) -> Data {
        Data((String(repeating: "0", count: 10) + String(epochSeconds)).suffix(10).utf8)
    }

    static func fileListQuery() -> Data { Data([0, 0]) }
    static func firmwareURL(_ url: String) -> Data { Data([1]) + Data(url.utf8) }
    static func oneByte(_ value: Int) -> Data { Data([UInt8(clamping: value)]) }

    static func recordDuration(seconds: Int) throws -> Data {
        guard let profile = DeviceCapabilities.allRecordDurationSeconds.firstIndex(of: seconds) else {
            throw Gen1ProtocolError.unsupportedRecordDuration
        }
        return Data([UInt8(profile)])
    }

    static func imageChunkAck(_ nextExpectedSequence: Int) throws -> Data {
        guard (0...0xFFFF).contains(nextExpectedSequence) else { throw Gen1ProtocolError.invalidImageSequence }
        return Data([0x05, UInt8(nextExpectedSequence >> 8), UInt8(nextExpectedSequence & 0xFF)])
    }

    static func imageRetransmitRequest(_ sequences: [Int]) throws -> Data {
        guard (1...8).contains(sequences.count) else { throw Gen1ProtocolError.invalidRetransmitCount }
        guard sequences.allSatisfy({ (0...0xFFFF).contains($0) }) else { throw Gen1ProtocolError.invalidImageSequence }
        var payload = Data([0x04, UInt8(sequences.count)])
        for sequence in sequences { payload.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xFF)]) }
        return payload
    }
}

enum Gen1FileListParser {
    static func parseMediaFiles(_ payload: Data) -> [String] {
        let supported = Set(["jpg", "jpeg", "png", "mp4", "mov", "avi"])
        return String(decoding: payload, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 \r\n\t"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { name in
                guard !name.isEmpty, !name.contains(".."), !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return false }
                let lower = name.lowercased()
                return supported.contains((lower as NSString).pathExtension)
                    && !["thumb", "thumbnail", "preview", "_small"].contains(where: lower.contains)
            }
    }
}

/// Shared application values, not G5K61 wire values. Keep aligned with Android's
/// DeviceStatusManager and the canonical devstatus0 consumer.
enum Gen1DomainDeviceStatus: UInt8, Sendable {
    case standby = 0, photoTaking = 1, videoRecording = 2, networkOperating = 7, shuttingDown = 8, unknown = 0xFF
}

enum Gen1DeviceStatusMapper {
    static func toDomainStatus(_ rawStatus: UInt8) -> Gen1DomainDeviceStatus {
        switch rawStatus {
        case 0: return .standby
        case 1: return .videoRecording
        case 2: return .networkOperating
        case 3: return .photoTaking
        case 4: return .shuttingDown
        default: return .unknown
        }
    }
}

enum Gen1VoiceRoute: Equatable, Sendable {
    case ai(Gen1VoiceFrame)
    case translationStarted
    case translationData(sequence: Int, opus: Data)
    case translationStopped
    case translationStartFailed
    case translationStreamError(reason: String)
    case ignore
}

/// The END frame, rather than the stop ACK, is the authoritative stream boundary.
final class Gen1TranslationAudioRouter {
    private enum State { case idle, pendingStart, streaming, pendingStop, discarding }
    private var state = State.idle
    private let lock = NSLock()

    func onStartRequested() {
        lock.lock(); defer { lock.unlock() }
        state = .pendingStart
    }

    func onStartFailed() {
        lock.lock(); defer { lock.unlock() }
        if state == .pendingStart { state = .idle }
    }

    func onStopRequested() {
        lock.lock(); defer { lock.unlock() }
        if state == .pendingStart || state == .streaming { state = .pendingStop }
    }

    func onAck(_ status: UInt8) -> Gen1VoiceRoute {
        lock.lock(); defer { lock.unlock() }
        if status == 0, state == .pendingStart { state = .idle; return .translationStartFailed }
        return .ignore
    }

    func onFrame(_ frame: Gen1VoiceFrame) -> Gen1VoiceRoute {
        lock.lock(); defer { lock.unlock() }
        switch frame.type {
        case .start:
            // A delayed START can belong to the translation we just stopped.
            // Quarantine its whole stream until END, not only trailing DATA.
            if state == .discarding { return .ignore }
            if state == .pendingStart, frame.sequence == 0 { state = .streaming; return .translationStarted }
            return .ai(frame)
        case .data:
            if state == .discarding { return .ignore }
            return state == .streaming || state == .pendingStop
                ? .translationData(sequence: frame.sequence, opus: frame.payload) : .ai(frame)
        case .end:
            switch state {
            case .streaming, .pendingStop: state = .idle; return .translationStopped
            case .pendingStart: return .ignore
            case .discarding: state = .idle; return .ignore
            case .idle: return .ai(frame)
            }
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        state = .idle
    }

    /// Abandon a cancelled/timed-out translation without treating its trailing DATA as AI.
    /// END or an explicit AI wake-up restores normal routing. An explicit translation start also wins.
    func discardPendingStream() {
        lock.lock(); defer { lock.unlock() }
        if state != .idle { state = .discarding }
    }

    /// Only an explicit AI control event may recover when a cancelled stream lost its END.
    func onAIWakeup() {
        lock.lock(); defer { lock.unlock() }
        if state == .discarding { state = .idle }
    }
}

enum Gen1ImageEvent: Equatable, Sendable {
    case started(expectedChunks: Int)
    case progress(receivedChunks: Int, expectedChunks: Int, receivedBytes: Int, shouldSendAck: Bool, nextExpectedSequence: Int)
    case needRetransmit(missingSequences: [Int], round: Int, expectedChunks: Int, receivedChunks: Int, receivedBytes: Int)
    case completed(jpeg: Data)
    case error(reason: String)
}

/// Photo Recognize 2 assembler with cumulative ACKs, out-of-order chunks and bounded retransmission.
final class Gen1ImageAssembler {
    static let maxJPEGSize = 8 * 1024 * 1024
    static let maxRetransmitRounds = 3
    static let ackWindow = 16
    private var chunks: [Int: Data] = [:]
    private var receiving = false
    private var expectedChunks = 0
    private var receivedByteCount = 0
    private var lastContiguousSequence = -1
    private var ackWindowCount = 0
    private var retransmitRound = 0
    private var endStatus: UInt8?
    private var endCrc: UInt16?
    private var endLength: Int?
    private let lock = NSRecursiveLock()

    func append(_ payload: Data) -> Gen1ImageEvent? {
        lock.lock(); defer { lock.unlock() }
        let bytes = [UInt8](payload)
        guard let type = bytes.first else { return fail("empty image payload") }
        switch type {
        case 1: return handleStart(bytes)
        case 2: return handleData(bytes)
        case 3: return handleEnd(bytes)
        default: return fail("unknown image packet type")
        }
    }

    /// Retry after a retransmission timeout; peers need not send another END packet.
    func requestRetransmission() -> Gen1ImageEvent? {
        lock.lock(); defer { lock.unlock() }
        guard receiving, endLength != nil else { return nil }
        return finishOrRequestRetransmit()
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        chunks.removeAll()
        receiving = false
        expectedChunks = 0
        receivedByteCount = 0
        lastContiguousSequence = -1
        ackWindowCount = 0
        retransmitRound = 0
        endStatus = nil
        endCrc = nil
        endLength = nil
    }

    private func handleStart(_ bytes: [UInt8]) -> Gen1ImageEvent {
        reset()
        guard bytes.count >= 4 else { return fail("invalid image START packet") }
        guard bytes[1] == 0 else { return fail("image capture rejected: \(bytes[1])") }
        let count = Int(bytes[2]) << 8 | Int(bytes[3])
        guard count > 0 else { return fail("invalid image chunk count") }
        receiving = true
        expectedChunks = count
        return .started(expectedChunks: count)
    }

    private func handleData(_ bytes: [UInt8]) -> Gen1ImageEvent {
        guard receiving else { return fail("image DATA received before START") }
        guard bytes.count >= 4 else { return fail("invalid image DATA packet") }
        let sequence = Int(bytes[1]) << 8 | Int(bytes[2])
        guard sequence < expectedChunks else { return fail("image sequence out of range: seq=\(sequence) chunks=\(expectedChunks)") }
        let isNew = chunks[sequence] == nil
        if isNew {
            let size = bytes.count - 3
            guard size <= Self.maxJPEGSize - receivedByteCount else { return fail("image is too large") }
            chunks[sequence] = Data(bytes.dropFirst(3))
            receivedByteCount += size
        }
        let previousContiguous = lastContiguousSequence
        if isNew, sequence == lastContiguousSequence + 1 {
            while chunks[lastContiguousSequence + 1] != nil { lastContiguousSequence += 1 }
            ackWindowCount += 1
        }
        let gapFilled = lastContiguousSequence > sequence
            || (previousContiguous != lastContiguousSequence && lastContiguousSequence > previousContiguous + 1)
        let next = lastContiguousSequence + 1
        let sendAck = isNew && sequence <= lastContiguousSequence
            && (next >= expectedChunks || gapFilled || ackWindowCount >= Self.ackWindow)
        if sendAck { ackWindowCount = 0 }
        // A failure END with holes can be recovered by DATA-only retransmission.
        if endCrc != nil, endLength != nil, chunks.count == expectedChunks { return completeIfValid() }
        return .progress(receivedChunks: chunks.count, expectedChunks: expectedChunks, receivedBytes: receivedByteCount,
                         shouldSendAck: sendAck, nextExpectedSequence: next)
    }

    private func handleEnd(_ bytes: [UInt8]) -> Gen1ImageEvent {
        guard receiving else { return fail("image END received before START") }
        guard bytes.count >= 8 else { return fail("invalid image END packet") }
        let length = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        guard length <= Self.maxJPEGSize else { return fail("image is too large") }
        let crc = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        if let previousLength = endLength, let previousCrc = endCrc {
            guard previousLength == length, previousCrc == crc else { return fail("image END metadata changed") }
            // Duplicate END notifications must not consume the retry budget or restart
            // a batch of outstanding retransmission requests. Timeouts drive retries.
            return .progress(receivedChunks: chunks.count, expectedChunks: expectedChunks,
                             receivedBytes: receivedByteCount, shouldSendAck: false,
                             nextExpectedSequence: lastContiguousSequence + 1)
        }
        endStatus = bytes[1]
        endCrc = crc
        endLength = length
        return finishOrRequestRetransmit()
    }

    private func finishOrRequestRetransmit() -> Gen1ImageEvent {
        let missing = (0..<expectedChunks).filter { chunks[$0] == nil }
        if !missing.isEmpty {
            guard retransmitRound < Self.maxRetransmitRounds else {
                return fail("image chunks still missing after \(Self.maxRetransmitRounds) retransmit rounds")
            }
            retransmitRound += 1
            return .needRetransmit(missingSequences: missing, round: retransmitRound, expectedChunks: expectedChunks,
                                   receivedChunks: chunks.count, receivedBytes: receivedByteCount)
        }
        guard endStatus == 0 else { return fail("image transfer failed: \(endStatus.map(Int.init) ?? -1)") }
        return completeIfValid()
    }

    private func completeIfValid() -> Gen1ImageEvent {
        guard let length = endLength, let crc = endCrc else { return fail("image END was not received") }
        var jpeg = Data(capacity: receivedByteCount)
        for sequence in 0..<expectedChunks { if let chunk = chunks[sequence] { jpeg.append(chunk) } }
        guard length == jpeg.count else { return fail("image length mismatch: expected=\(length) actual=\(jpeg.count)") }
        guard Gen1ControlCodec.crc16Modbus(jpeg) == crc else { return fail("image CRC mismatch") }
        guard jpeg.count >= 4, jpeg.prefix(2) == Data([0xFF, 0xD8]), jpeg.suffix(2) == Data([0xFF, 0xD9]) else {
            return fail("invalid JPEG markers")
        }
        reset()
        return .completed(jpeg: jpeg)
    }

    private func fail(_ reason: String) -> Gen1ImageEvent {
        reset()
        return .error(reason: reason)
    }
}

struct Gen1StorageInfo: Equatable, Sendable {
    let total: String
    let used: String
    var displayValue: String { "\(total) / \(used)" }
}

enum Gen1StorageParser {
    static func parse(_ payload: Data) -> String? { parseValues(payload)?.displayValue }

    static func parseValues(_ payload: Data) -> Gen1StorageInfo? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 3, bytes[0] == 0 else { return nil }
        let totalLength = Int(bytes[1])
        guard totalLength > 0, totalLength <= 16, bytes.count >= 3 + totalLength else { return nil }
        let usedOffset = 2 + totalLength
        let usedLength = Int(bytes[usedOffset])
        guard usedLength > 0, usedLength <= 16, bytes.count == usedOffset + 1 + usedLength else { return nil }
        let total = bytes[2..<usedOffset]
        let used = bytes[(usedOffset + 1)...]
        guard total.allSatisfy({ (0x21...0x7E).contains($0) }), used.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return Gen1StorageInfo(total: String(decoding: total, as: UTF8.self), used: String(decoding: used, as: UTF8.self))
    }
}

/// First-generation 0x02 recording stream is 16 kHz, mono, signed little-endian PCM16.
enum Gen1PCM {
    static let sampleRate = 16_000
    static let bytesPerSecond = 32_000

    static func wavHeader(pcmBytes: UInt32) -> Data {
        var header = Data()
        func appendLE(_ value: UInt32, bytes: Int) {
            for index in 0..<bytes { header.append(UInt8((value >> (8 * index)) & 0xFF)) }
        }
        header.append(Data("RIFF".utf8))
        appendLE(pcmBytes &+ 36, bytes: 4)
        header.append(Data("WAVEfmt ".utf8))
        appendLE(16, bytes: 4)
        appendLE(1, bytes: 2)
        appendLE(1, bytes: 2)
        appendLE(UInt32(sampleRate), bytes: 4)
        appendLE(UInt32(bytesPerSecond), bytes: 4)
        appendLE(2, bytes: 2)
        appendLE(16, bytes: 2)
        header.append(Data("data".utf8))
        appendLE(pcmBytes, bytes: 4)
        return header
    }
}
