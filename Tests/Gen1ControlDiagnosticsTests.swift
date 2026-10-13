import Foundation

@main
enum Gen1ControlDiagnosticsTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        checks += 1
        guard condition() else { throw Failure(description: name) }
    }

    static func response(_ command: UInt8, _ payload: Data = Data()) throws -> Data {
        var packet = try Gen1ControlCodec.buildCommand(command: command, payload: payload)
        packet[1] = Gen1ControlCodec.device
        packet[2] = Gen1ControlCodec.app
        let crc = Gen1ControlCodec.crc16Modbus(packet.dropLast(2))
        packet[packet.count - 2] = UInt8(crc & 0xFF)
        packet[packet.count - 1] = UInt8(crc >> 8)
        return packet
    }

    static func main() throws {
        try splitAndCoalescedFrames()
        try discardedCandidatesAndRecovery()
        try resetAndLegacyAPI()
        try payloadPrivacy()
        print("Gen1 control diagnostics: \(checks) assertions passed")
    }

    static func splitAndCoalescedFrames() throws {
        let packet = try response(Gen1Commands.tutorial, Data([8, 1]))
        let pause = try response(Gen1Commands.mediaPause)
        for cut in 0...packet.count {
            let decoder = Gen1ControlStreamDecoder()
            let first = decoder.appendWithDiagnostics(packet.prefix(cut))
            try check(first.inputBytes == cut && first.bufferedBytesBefore == 0, "split \(cut): input counts")
            try check(first.frames.count == (cut == packet.count ? 1 : 0), "split \(cut): no premature delivery")
            try check(first.bufferedBytes == (cut == packet.count ? 0 : cut), "split \(cut): retained prefix")
            let expected = cut >= Gen1ControlCodec.headerSize && cut < packet.count ? packet.count : nil
            try check(first.expectedFrameBytes == expected, "split \(cut): declared frame size")
            let waiting = cut == 0 || cut == packet.count ? "none" : (cut < 6 ? "header" : "frame")
            try check(first.diagnosticSummary.contains("waiting=\(waiting)"), "split \(cut): wait reason")
            try check(first.noiseDiscardedBytes == 0 && first.crcFailures == 0 && first.oversizedLengthDiscards == 0,
                      "split \(cut): normal fragmentation is not corruption")

            let second = decoder.appendWithDiagnostics(packet.dropFirst(cut) + pause)
            try check(second.bufferedBytesBefore == first.bufferedBytes, "split \(cut): prior fragment visible")
            try check((first.frames + second.frames).map(\.raw) == [packet, pause], "split \(cut): complete ordered frames")
            try check(second.bufferedBytes == 0 && second.expectedFrameBytes == nil, "split \(cut): fully drained")
            try check(second.diagnosticSummary.contains("decodedFrames=\(second.frames.count)"), "split \(cut): decoded count")
        }

        let payload = Data((0..<530).map { UInt8($0 & 0xFF) })
        let large = try response(Gen1Commands.deviceName, payload)
        for chunkSize in [1, 2, 5, 6, 20, 185, 244] {
            let decoder = Gen1ControlStreamDecoder()
            var frames: [Gen1ControlFrame] = []
            for start in stride(from: 0, to: large.count, by: chunkSize) {
                let end = min(start + chunkSize, large.count)
                let result = decoder.appendWithDiagnostics(large[start..<end])
                frames += result.frames
                try check(result.noiseDiscardedBytes == 0 && result.crcFailures == 0,
                          "chunk \(chunkSize) at \(start): no false drop")
                try check(result.bufferedBytes == (end == large.count ? 0 : end),
                          "chunk \(chunkSize) at \(start): accumulating continuation")
            }
            try check(frames.count == 1 && frames[0].payload == payload, "chunk \(chunkSize): payload preserved")
        }

        let decoder = Gen1ControlStreamDecoder()
        let result = decoder.appendWithDiagnostics(packet + pause + packet.prefix(7))
        try check(result.frames.map(\.raw) == [packet, pause], "coalesced frames before partial tail")
        try check(result.bufferedBytes == 7 && result.expectedFrameBytes == packet.count, "coalesced partial tail reported")
        try check(decoder.appendWithDiagnostics(packet.dropFirst(7)).frames.first?.raw == packet, "coalesced tail recovered")

        let maximum = try response(Gen1Commands.deviceName, Data(repeating: 4, count: Gen1ControlCodec.maxPayloadSize))
        let maxDecoder = Gen1ControlStreamDecoder()
        let prefix = maxDecoder.appendWithDiagnostics(maximum.dropLast())
        try check(prefix.expectedFrameBytes == maximum.count && prefix.bufferedBytes == maximum.count - 1,
                  "maximum legal frame awaits final CRC byte")
        let complete = maxDecoder.appendWithDiagnostics(maximum.suffix(1))
        try check(complete.frames.first?.raw == maximum && complete.overflowDiscardedBytes == 0,
                  "maximum legal frame is not overflow")
    }

    static func discardedCandidatesAndRecovery() throws {
        let good = try response(Gen1Commands.tutorial, Data([8, 1]))
        let pause = try response(Gen1Commands.mediaPause)
        let decoder = Gen1ControlStreamDecoder()
        let noise = decoder.appendWithDiagnostics(Data([0, 1, 2, 3]))
        try check(noise.frames.isEmpty && noise.noiseDiscardedBytes == 4 && noise.bufferedBytes == 0, "noise counted and dropped")
        try check(noise.crcFailures == 0 && noise.oversizedLengthDiscards == 0, "noise is not bad CRC or oversized length")

        var badCRC = good
        badCRC[badCRC.count - 1] ^= 0xFF
        let first = decoder.appendWithDiagnostics(badCRC.dropLast())
        try check(first.crcFailures == 0 && first.bufferedBytes == badCRC.count - 1, "incomplete CRC waits without rejection")
        let recovered = decoder.appendWithDiagnostics(badCRC.suffix(1) + good)
        try check(recovered.crcFailures == 1 && recovered.frames.first?.raw == good, "bad CRC followed by valid frame recovers")
        try check(recovered.noiseDiscardedBytes == badCRC.count - 1 && recovered.bufferedBytes == 0,
                  "bad candidate remainder counted as resynchronization noise")
        try check(recovered.diagnosticSummary.contains("crcFailures=1"), "CRC rejection appears in summary")

        let oversized = Data([0xAA, 3, 2, 0x81, 0x40, 0x01])
        let oversizedDecoder = Gen1ControlStreamDecoder()
        try check(oversizedDecoder.appendWithDiagnostics(oversized.prefix(5)).oversizedLengthDiscards == 0,
                  "partial oversized header waits for length")
        let rejected = oversizedDecoder.appendWithDiagnostics(oversized.suffix(1) + pause.prefix(3))
        try check(rejected.oversizedLengthDiscards == 1 && rejected.crcFailures == 0, "oversized length classified before CRC")
        try check(rejected.noiseDiscardedBytes == 5 && rejected.bufferedBytes == 3 && rejected.expectedFrameBytes == nil,
                  "oversized header rejected while following partial header retained")
        try check(rejected.diagnosticSummary.contains("oversizedLengthDiscards=1"), "oversized discard appears in summary")
        let next = oversizedDecoder.appendWithDiagnostics(pause.dropFirst(3))
        try check(next.frames.first?.raw == pause && next.oversizedLengthDiscards == 0, "oversized counters scoped to notification")

        // Corrupt length makes a rejected candidate encompass an otherwise valid frame.
        var nested = try response(Gen1Commands.deviceName, good)
        nested[nested.count - 1] ^= 0xFF
        let nestedResult = Gen1ControlStreamDecoder().appendWithDiagnostics(nested + pause)
        try check(nestedResult.crcFailures == 1 && nestedResult.frames.map(\.raw) == [good, pause],
                  "CRC resynchronization searches within damaged candidate")

        let bulk = Gen1ControlStreamDecoder().appendWithDiagnostics(Data(repeating: 0, count: 100_000) + good)
        try check(bulk.noiseDiscardedBytes == 100_000 && bulk.frames.first?.raw == good && bulk.bufferedBytes == 0,
                  "large noise burst recovery")
        try check(bulk.diagnosticSummary.contains("noiseDiscardedBytes=100000"), "large discard count logged")
    }

    static func resetAndLegacyAPI() throws {
        let packet = try response(Gen1Commands.tutorial, Data([8, 1]))
        let decoder = Gen1ControlStreamDecoder()
        let start = decoder.appendWithDiagnostics(packet.prefix(7))
        let empty = decoder.appendWithDiagnostics(Data())
        try check(empty.inputBytes == 0 && empty.frames.isEmpty, "empty input emits no frame")
        try check(empty.bufferedBytesBefore == 7 && empty.bufferedBytes == 7 && empty.expectedFrameBytes == packet.count,
                  "empty input preserves wait diagnostics")
        try check(decoder.append(packet.dropFirst(7)).first?.raw == packet, "legacy append consumes diagnostic prefix")
        try check(decoder.append(packet.prefix(4)).isEmpty, "legacy append buffers")
        try check(decoder.appendWithDiagnostics(packet.dropFirst(4)).frames.first?.raw == packet,
                  "diagnostic append consumes legacy prefix")
        _ = decoder.appendWithDiagnostics(packet.prefix(7))
        decoder.reset()
        let afterReset = decoder.appendWithDiagnostics(Data())
        try check(afterReset.bufferedBytesBefore == 0 && afterReset.bufferedBytes == 0 && afterReset.expectedFrameBytes == nil,
                  "reset clears buffered state and expected length")
        try check(decoder.appendWithDiagnostics(packet).frames.first?.raw == packet, "fresh complete frame after reset")
        try check(start.bufferedBytes == 7 && start.frames.isEmpty, "result is immutable snapshot")

        var sliced = Data([0, 0]) + packet
        sliced.removeFirst(2)
        let slicedResult = decoder.appendWithDiagnostics(sliced)
        try check(sliced.startIndex > 0 && slicedResult.inputBytes == packet.count && slicedResult.frames.first?.raw == packet,
                  "nonzero Data indices accepted")
    }

    static func payloadPrivacy() throws {
        let privateText = "PRIVATE_SSID/PRIVATE_PASSWORD"
        let packet = try response(Gen1Commands.openHotspot, Data(privateText.utf8))
        let result = Gen1ControlStreamDecoder().appendWithDiagnostics(packet)
        let summary = result.diagnosticSummary
        try check(result.frames.first?.payload == Data(privateText.utf8), "payload remains available to protocol consumer")
        try check(!summary.contains("PRIVATE") && !summary.contains("SSID") && !summary.contains("PASSWORD"),
                  "diagnostics never include Wi-Fi credentials")
        try check(!summary.contains("payload=") && !summary.contains("raw="), "diagnostics contain no raw payload fields")
        try check(summary.contains("inputBytes=\(packet.count)") && summary.contains("decodedFrames=1") &&
                  summary.contains("bufferedBytes=0") && summary.contains("expectedFrameBytes=none") &&
                  summary.contains("waiting=none") && summary.contains("overflowDiscardedBytes=0"),
                  "complete summary contains packet and buffer disposition")
    }
}
