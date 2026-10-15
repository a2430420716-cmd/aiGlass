import Foundation
@preconcurrency import Network

@main
enum Gen1MediaTCPTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var assertions = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try condition() else { throw Failure(description: message) }
    }

    static func expectFailure(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { assertions += 1; return }
        throw Failure(description: message)
    }

    static func hex(_ value: String) -> Data {
        Data(value.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    /// Device-side fixture, independently specifies the documented wire layout.
    static func response(_ command: UInt16, _ body: Data = Data(), external: Int = 0, tail: Data = Data([0xAF, 0x8C]), littleEndianRouting: Bool = false) -> Data {
        let length = body.count + 20
        let header: [UInt8] = [0xAF, 0x8C, 0, 1, UInt8(command >> 8), UInt8(command & 255),
                               0, 3, 0, 2, 0, 0, UInt8(external >> 8), UInt8(external & 255),
                               UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
                               UInt8((length >> 8) & 255), UInt8(length & 255)]
        var bytes = header
        if littleEndianRouting {
            for offset in [2, 6, 8] { bytes.swapAt(offset, offset + 1) }
        }
        return Data(bytes) + body + tail
    }

    static func main() async throws {
        // Fail deterministically if a continuation or cancellation ever leaks.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled else { return }
            fputs("Gen1 TCP test watchdog expired\n", stderr)
            exit(2)
        }
        defer { watchdog.cancel() }
        try protocolTests()
        #if GEN1_MEDIA_TCP_TESTING
        if !CommandLine.arguments.contains("--protocol-only") {
            try await integrationTests()
        }
        #endif
        print("Gen1 media TCP: \(assertions) assertions passed")
    }

    static func protocolTests() throws {
        let fileRequest = try Gen1MediaTCPProtocol.request(.sendFile, payload: Data("A.JPG".utf8))
        try check(fileRequest == hex("AF 8C 00 01 00 01 00 02 00 03 00 00 00 05 00 00 00 19 41 2E 4A 50 47 AF 8C"), "documented filename request layout")
        let heartbeat = try Gen1MediaTCPProtocol.request(.heartbeat)
        try check(heartbeat == hex("AF 8C 00 01 00 06 00 02 00 03 00 00 00 00 00 00 00 14 AF 8C"), "heartbeat wire vector")
        let docName = Data("2026-09-21-10-20-30.jpg".utf8)
        let docRequest = try Gen1MediaTCPProtocol.request(.sendFile, payload: docName)
        try check(docRequest[12] == 0 && docRequest[13] == 0x17 && docRequest[17] == 0x2B, "correct inconsistent external_length in document example")
        let name = Data("A.JPG".utf8)
        let body = name + Data(repeating: 0x81, count: 70_000)
        let frame = response(1, body, external: name.count)
        let header = try Gen1MediaTCPProtocol.parseResponseHeader(frame.prefix(18))
        let fileLength = try Gen1MediaTCPProtocol.fileLength(header: header, requestedName: name)
        try check(fileLength == 70_000 && header.bodyLength == 70_005, "external length counted once; file larger than UInt16")
        // Literal device wire vector: routing LE, command and lengths still BE.
        let mixedHeader = try Gen1MediaTCPProtocol.parseResponseHeader(hex("AF 8C 01 00 00 01 03 00 02 00 00 00 00 05 00 01 11 89"))
        try check(mixedHeader == header, "mixed-endian routing normalizes to existing response metadata")
        try check(try Gen1MediaTCPProtocol.fileLength(header: mixedHeader, requestedName: name) == 70_000,
                  "mixed-endian file length remains network order")
        let mixedList = try Gen1MediaTCPProtocol.parseResponseHeader(hex("AF 8C 01 00 00 03 03 00 02 00 00 00 00 00 00 00 00 14"))
        try check(mixedList.command == 3 && mixedList.bodyLength == 0 && !mixedList.usesLegacyRouting,
                  "mixed-endian list response accepted without relaxing legacy length rules")
        let mixedHeartbeat = try Gen1MediaTCPProtocol.parseResponseHeader(hex("AF 8C 01 00 00 06 03 00 02 00 00 00 00 00 00 00 00 14"))
        try check(mixedHeartbeat.command == 6, "mixed-endian heartbeat response accepted")
        // Reject every inconsistent permutation: all three routing fields share one order.
        for mask in 1..<7 {
            var inconsistent = Data(frame.prefix(18))
            for (bit, offset) in [2, 6, 8].enumerated() where mask & (1 << bit) != 0 {
                inconsistent.swapAt(offset, offset + 1)
            }
            try expectFailure("inconsistent routing byte order rejected: \(mask)") {
                _ = try Gen1MediaTCPProtocol.parseResponseHeader(inconsistent)
            }
        }
        var mixedEcho = Data(fileRequest.prefix(18))
        for offset in [2, 6, 8] { mixedEcho.swapAt(offset, offset + 1) }
        try expectFailure("LE request echo rejected as response") { _ = try Gen1MediaTCPProtocol.parseResponseHeader(mixedEcho) }
        var mixedBadExternal = Data(frame.prefix(18))
        for offset in [2, 6, 8] { mixedBadExternal.swapAt(offset, offset + 1) }
        mixedBadExternal[13] = 0
        try expectFailure("mixed-endian routing preserves filename length validation") {
            _ = try Gen1MediaTCPProtocol.fileLength(header: Gen1MediaTCPProtocol.parseResponseHeader(mixedBadExternal), requestedName: name)
        }
        var legacy = Data(frame.prefix(18))
        for index in [2, 3, 6, 7, 8, 9] { legacy[index] = 0 }
        for external in [0, name.count, body.count & 0xFFFF] {
            legacy[12] = UInt8(external >> 8)
            legacy[13] = UInt8(external & 255)
            let parsed = try Gen1MediaTCPProtocol.parseResponseHeader(legacy)
            let size = try Gen1MediaTCPProtocol.fileLength(header: parsed, requestedName: name)
            try check(size == 70_000 && parsed.usesLegacyRouting, "bounded legacy header compatibility \(external)")
        }
        var unknownLegacy = legacy
        unknownLegacy[12] = 0
        unknownLegacy[13] = 1
        try expectFailure("unknown legacy length rejected") {
            _ = try Gen1MediaTCPProtocol.fileLength(header: Gen1MediaTCPProtocol.parseResponseHeader(unknownLegacy), requestedName: name)
        }
        let mutations: [(Int, UInt8, String)] = [(0, 0, "magic"), (3, 2, "version"), (7, 2, "sender"), (9, 3, "receiver"), (11, 1, "reserved")]
        for (index, value, message) in mutations {
            var invalid = Data(frame.prefix(18))
            invalid[index] = value
            try expectFailure("invalid \(message) rejected") { _ = try Gen1MediaTCPProtocol.parseResponseHeader(invalid) }
        }
        try expectFailure("request echo rejected as response") { _ = try Gen1MediaTCPProtocol.parseResponseHeader(fileRequest.prefix(18)) }
        try expectFailure("truncated header rejected") { _ = try Gen1MediaTCPProtocol.parseResponseHeader(frame.prefix(17)) }
        var tooShort = Data(frame.prefix(18))
        tooShort.replaceSubrange(14..<18, with: [0, 0, 0, 19])
        try expectFailure("undersized total rejected") { _ = try Gen1MediaTCPProtocol.parseResponseHeader(tooShort) }
        let badExternal = try Gen1MediaTCPProtocol.parseResponseHeader(response(1, body, external: 0).prefix(18))
        try expectFailure("modern external length validated") { _ = try Gen1MediaTCPProtocol.fileLength(header: badExternal, requestedName: name) }
        try expectFailure("header-only missing file rejected") {
            _ = try Gen1MediaTCPProtocol.fileLength(header: Gen1MediaTCPProtocol.parseResponseHeader(response(1).prefix(18)), requestedName: name)
        }
        try Gen1MediaTCPProtocol.validateTrailer(Data([0xAF, 0x8C]))
        try Gen1MediaTCPProtocol.validateTrailer(Data([0x8C, 0xAF]))
        for version in [hex("00 01"), hex("01 00")] {
            for payload in [Data(), Data("photo.jpg,video.mp4".utf8)] {
                var documented = response(3, payload, tail: hex("8C AF"))
                documented.replaceSubrange(2..<4, with: version)
                documented.replaceSubrange(6..<10, with: [0, 0, 0, 0])
                let parsed = try Gen1MediaTCPProtocol.parseResponseHeader(documented.prefix(18))
                try check(parsed.command == 3 && parsed.bodyLength == payload.count && !parsed.usesLegacyRouting,
                          "documented version-1 zero IDs retain modern length rules")
                try Gen1MediaTCPProtocol.validateTrailer(documented.suffix(2))
                try check(try Gen1MediaTCPProtocol.parseFileList(documented.dropFirst(18).dropLast(2)) == (payload.isEmpty ? [] : ["photo.jpg", "video.mp4"]),
                          "documented empty/populated list with LE trailer")
            }
        }
        var zeroRoutingFile = response(1, body, external: 0)
        zeroRoutingFile.replaceSubrange(6..<10, with: [0, 0, 0, 0])
        try expectFailure("zero IDs with version 1 do not relax filename length validation") {
            _ = try Gen1MediaTCPProtocol.fileLength(header: Gen1MediaTCPProtocol.parseResponseHeader(zeroRoutingFile.prefix(18)), requestedName: name)
        }
        for malformedTail in [Data(), hex("8C"), hex("AF 8C 00"), hex("8C 8C")] {
            try expectFailure("malformed placeholder trailer rejected") { try Gen1MediaTCPProtocol.validateTrailer(malformedTail) }
        }
        try expectFailure("nonconstant trailer rejected") { try Gen1MediaTCPProtocol.validateTrailer(Data([0, 0])) }
        try expectFailure("oversized outgoing payload rejected") {
            _ = try Gen1MediaTCPProtocol.request(.sendFile, payload: Data(repeating: 1, count: 65_536))
        }
        let list = Data(" A.JPG,clip.mp4,A.JPG,clip_thumb.jpg,preview.png,../bad.jpg,bad/path.jpg,bad\\path.jpg,.hidden.jpg,notes.txt,测试照片.jpeg\0\r\n".utf8)
        try check(try Gen1MediaTCPProtocol.parseFileList(list) == ["A.JPG", "clip.mp4", "测试照片.jpeg"], "safe media list, thumbnails and duplicates")
        try check(try Gen1MediaTCPProtocol.parseFileList(Data()).isEmpty, "empty file list")
        for name in ["../a.jpg", "/a.jpg", "a\\b.jpg", ".jpg", "a.jpg?x=1", "a\0.jpg", "a\n.jpg", "a.txt", "a_small.jpg", " a.jpg", "a.jpg "] {
            try expectFailure("unsafe filename rejected: \(name)") { _ = try Gen1MediaTCPProtocol.validateFileName(name) }
        }
        try expectFailure("non-UTF8 list rejected") { _ = try Gen1MediaTCPProtocol.parseFileList(Data([0xFF])) }
        try expectFailure("list allocation bound enforced") { _ = try Gen1MediaTCPProtocol.parseFileList(Data(repeating: 65, count: 4 * 1024 * 1024 + 1)) }
        let unicodeName = String(repeating: "图", count: 84) + ".jpg"
        try expectFailure("filename bound uses UTF8 byte count") { _ = try Gen1MediaTCPProtocol.validateFileName(unicodeName) }
        var offsetHeader = Data([9, 9]) + frame.prefix(18)
        offsetHeader.removeFirst(2)
        try check(try Gen1MediaTCPProtocol.parseResponseHeader(offsetHeader) == header, "Data slice nonzero start index")
    }

    #if GEN1_MEDIA_TCP_TESTING
    static func integrationTests() async throws {
        try await successfulBatch()
        try await rejectedDownloads()
        try await idleAndOperationTimeouts()
        try await fileTransferTimeouts()
        try await cancellationPreservesPartial()
        try await existingFilesNeverOverwritten()
        try await destinationPublicationRace()
        try await closeReleasesRead()
        try await receiveErrorPreservesDeliveredBytes()
    }

    static func configuration() -> Gen1MediaTCPTestConfiguration {
        Gen1MediaTCPTestConfiguration(connectTimeout: 2, readIdleTimeout: 1, writeTimeout: 1,
                                     fileListTimeout: 2, downloadTimeout: 3, heartbeatInterval: 0.04)
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gen1-tcp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func successfulBatch() async throws {
        let image = Data((0..<262_157).map { UInt8($0 & 255) })
        let video = Data(repeating: 0x81, count: 131_119)
        let server = LoopbackPeer { command, payload in
            switch command {
            case 3:
                return .fragmented(response(6, littleEndianRouting: true) + response(3, Data("first.jpg,movie.mp4,first.jpg,preview.jpg".utf8), tail: Data([0x8C, 0xAF]), littleEndianRouting: true), sizes: [1, 2, 7, 17])
            case 1:
                let content = String(decoding: payload, as: UTF8.self) == "first.jpg" ? image : video
                return .fragmented(response(6, Data([1])) + response(1, payload + content, external: payload.count, littleEndianRouting: true), sizes: [3, 17, 4096, 65_536], interval: 0.002)
            case 6: return .fragmented(response(6), sizes: [20])
            default: return .none
            }
        }
        let port = try await server.start()
        let client = Gen1MediaTCPClient(host: "127.0.0.1", port: port, testConfiguration: configuration())
        let root = try directory()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        try await client.connect()
        let files = try await client.fileList()
        try check(files == ["first.jpg", "movie.mp4"], "split headers and concatenated heartbeat/list frames")
        // Simulates postprocessing between downloads: heartbeat must continue independently.
        try await Task.sleep(nanoseconds: 170_000_000)
        let firstURL = root.appendingPathComponent(files[0])
        let firstCount = try await client.downloadFile(named: files[0], to: firstURL)
        try check(firstCount == Int64(image.count) && (try Data(contentsOf: firstURL)) == image, "streamed large file published with exact content")
        try check(!FileManager.default.fileExists(atPath: firstURL.appendingPathExtension("partial").path), "atomic publication removes partial name")
        let secondURL = root.appendingPathComponent(files[1])
        let secondCount = try await client.downloadFile(named: files[1], to: secondURL)
        try check(secondCount == Int64(video.count) && (try Data(contentsOf: secondURL)) == video, "next file uses same TCP connection")
        try await client.finishTransfer()
        try await client.finishTransfer()
        try await Task.sleep(nanoseconds: 30_000_000)
        let requests = await server.snapshot()
        try check(requests.commands.filter { $0 == 7 }.count == 1, "batch completion sent exactly once")
        try check(requests.commands.filter { $0 == 1 }.count == 2 && requests.names == ["first.jpg", "movie.mp4"], "no download probes or duplicate GETs")
        try check(requests.commands.filter { $0 == 6 }.count >= 3, "heartbeat continues during idle postprocessing")
        try check(requests.invalidRequests == 0, "all request headers/lengths/trailers valid including serialized heartbeat writes")
        await client.close()
    }

    static func rejectedDownloads() async throws {
        for scenario in ["trailer", "filename", "missing", "truncated"] {
            let content = Data(repeating: 0x5A, count: 100)
            let server = LoopbackPeer { command, payload in
                guard command == 1 else { return .none }
                switch scenario {
                case "trailer": return .fragmented(response(1, payload + content, external: payload.count, tail: Data([0, 0])), sizes: [18, 9, 100, 2])
                case "filename": return .fragmented(response(1, Data("other.jpg".utf8) + content, external: payload.count), sizes: [18, 9, 100, 2])
                case "missing": return .fragmented(response(1), sizes: [20])
                default:
                    return .fragmented(Data(response(1, payload + content, external: payload.count).prefix(18 + payload.count + 7)), sizes: [18, 9, 7], closeAfter: true)
                }
            }
            let port = try await server.start()
            let client = Gen1MediaTCPClient(host: "127.0.0.1", port: port, testConfiguration: configuration())
            let root = try directory()
            defer { server.stop(); try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("first.jpg")
            try await client.connect()
            do {
                _ = try await client.downloadFile(named: "first.jpg", to: url)
                throw Failure(description: "\(scenario) accepted")
            } catch is Failure { throw Failure(description: "\(scenario) accepted") } catch { assertions += 1 }
            try check(!FileManager.default.fileExists(atPath: url.path), "\(scenario) never publishes invalid original")
            let partial = try Data(contentsOf: url.appendingPathExtension("partial"))
            let expected = scenario == "trailer" ? content : scenario == "truncated" ? Data(content.prefix(7)) : Data()
            try check(partial == expected, "\(scenario) preserves exactly the received file bytes")
            await client.close()
        }
    }

    static func idleAndOperationTimeouts() async throws {
        for heartbeatReplies in [false, true] {
            let server = LoopbackPeer { command, _ in
                command == 6 && heartbeatReplies ? .fragmented(response(6), sizes: [20]) : .none
            }
            let port = try await server.start()
            var config = configuration()
            // Keep the same idle-vs-overall assertion, but allow hosted Intel
            // scheduling and TCP delayed ACKs more than the old 120ms window.
            config.readIdleTimeout = 0.8
            config.fileListTimeout = 2.5
            config.heartbeatInterval = 0.05
            let client = Gen1MediaTCPClient(host: "127.0.0.1", port: port, testConfiguration: config)
            defer { server.stop() }
            try await client.connect()
            do {
                _ = try await client.fileList()
                throw Failure(description: "missing list did not time out")
            } catch Gen1MediaTCPError.timeout(let reason) {
                try check(reason == (heartbeatReplies ? "文件列表" : "数据接收"), "idle and overall deadlines distinguish heartbeat-only traffic: replies=\(heartbeatReplies) actual=\(reason)")
            }
            await client.close()
        }
    }

    static func fileTransferTimeouts() async throws {
        let content = Data(repeating: 0x73, count: 127)
        let server = LoopbackPeer { command, payload in
            guard command == 1 else { return .none }
            // Pauses exceed the control-read deadline but fit the file budget.
            return .fragmented(response(1, payload + content, external: payload.count),
                               sizes: [18, payload.count, 127, 2], interval: 0.15)
        }
        let port = try await server.start()
        var config = configuration()
        config.readIdleTimeout = 0.05
        let client = Gen1MediaTCPClient(host: "127.0.0.1", port: port, testConfiguration: config)
        let root = try directory()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        try await client.connect()
        for name in ["slow.jpg", "slow.mp4"] {
            let destination = root.appendingPathComponent(name)
            let count = try await client.downloadFile(named: name, to: destination)
            try check(count == Int64(content.count) && (try Data(contentsOf: destination)) == content,
                      "slow photo/video uses file budget, not control idle timeout")
        }
        do {
            _ = try await client.fileList()
            throw Failure(description: "control read retained file timeout")
        } catch Gen1MediaTCPError.timeout(let reason) {
            try check(reason == "数据接收", "control deadline restored after file download")
        }
        await client.close()

        for trickle in [false, true] {
            let peer = LoopbackPeer { command, payload in
                guard command == 1, trickle else { return .none }
                // Receiving some data must not extend the per-file total deadline.
                return .fragmented(response(1, payload + content, external: payload.count),
                                   sizes: [1], interval: 0.01)
            }
            let peerPort = try await peer.start()
            config.downloadTimeout = 0.25
            let bounded = Gen1MediaTCPClient(host: "127.0.0.1", port: peerPort, testConfiguration: config)
            defer { peer.stop() }
            try await bounded.connect()
            let destination = root.appendingPathComponent("bounded-\(trickle).mp4")
            do {
                _ = try await bounded.downloadFile(named: destination.lastPathComponent, to: destination)
                throw Failure(description: "file without complete response exceeded total deadline")
            } catch Gen1MediaTCPError.timeout(let reason) {
                try check(reason == "文件传输", "file deadline handles both silence and slow continuous data")
            }
            try check(!FileManager.default.fileExists(atPath: destination.path), "timed-out file not published")
            await bounded.close()
        }
    }

    static func cancellationPreservesPartial() async throws {
        let server = LoopbackPeer { command, payload in
            guard command == 1 else { return .none }
            let incomplete = response(1, payload + Data(repeating: 7, count: 1_000), external: payload.count).prefix(18 + payload.count + 7)
            return .fragmented(Data(incomplete), sizes: [18, payload.count, 7])
        }
        let port = try await server.start()
        let client = Gen1MediaTCPClient(host: "127.0.0.1", port: port, testConfiguration: configuration())
        let root = try directory()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        try await client.connect()
        let url = root.appendingPathComponent("first.jpg")
        let operation = Task { try await client.downloadFile(named: "first.jpg", to: url) }
        try await Task.sleep(nanoseconds: 90_000_000)
        do {
            _ = try await client.fileList()
            throw Failure(description: "concurrent read accepted")
        } catch Gen1MediaTCPError.operationInProgress { assertions += 1 }
        operation.cancel()
        do {
            _ = try await operation.value
            throw Failure(description: "cancelled download succeeded")
        } catch is CancellationError { assertions += 1 }
        try check(!FileManager.default.fileExists(atPath: url.path), "cancelled transfer not published")
        try check(try Data(contentsOf: url.appendingPathExtension("partial")) == Data(repeating: 7, count: 7), "cancellation drains waiter and preserves partial bytes")
        await client.close()
        await client.close()
    }

    static func existingFilesNeverOverwritten() async throws {
        for partialAlreadyExists in [false, true] {
            let server = LoopbackPeer { _, _ in .none }
            let port = try await server.start()
            let client = Gen1MediaTCPClient(host: "127.0.0.1", port: port, testConfiguration: configuration())
            let root = try directory()
            defer { server.stop(); try? FileManager.default.removeItem(at: root) }
            let destination = root.appendingPathComponent("first.jpg")
            let existing = partialAlreadyExists ? destination.appendingPathExtension("partial") : destination
            let original = Data("existing original".utf8)
            try original.write(to: existing)
            try await client.connect()
            do {
                _ = try await client.downloadFile(named: "first.jpg", to: destination)
                throw Failure(description: "existing file overwritten")
            } catch is Failure { throw Failure(description: "existing file overwritten") } catch { assertions += 1 }
            try check(try Data(contentsOf: existing) == original, "existing complete/partial original preserved")
            let snapshot = await server.snapshot()
            try check(!snapshot.commands.contains(1), "local collision detected before destructive device GET")
            await client.close()
        }
    }

    static func destinationPublicationRace() async throws {
        let root = try directory()
        let destination = root.appendingPathComponent("first.jpg")
        let original = Data("concurrently saved original".utf8)
        let downloaded = Data(repeating: 5, count: 127)
        let server = LoopbackPeer { command, payload in
            guard command == 1 else { return .none }
            // Appears after the client's preflight, but before final publication.
            try! original.write(to: destination)
            return .fragmented(response(1, payload + downloaded, external: payload.count), sizes: [18, 9, 127, 2])
        }
        let port = try await server.start()
        let client = Gen1MediaTCPClient(host: "127.0.0.1", port: port, testConfiguration: configuration())
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        try await client.connect()
        do {
            _ = try await client.downloadFile(named: "first.jpg", to: destination)
            throw Failure(description: "publication overwrote concurrent file")
        } catch is Failure { throw Failure(description: "publication overwrote concurrent file") } catch { assertions += 1 }
        try check(try Data(contentsOf: destination) == original, "publication cannot overwrite concurrent complete original")
        try check(try Data(contentsOf: destination.appendingPathExtension("partial")) == downloaded, "failed publication retains fully downloaded partial")
        await client.close()
    }

    static func closeReleasesRead() async throws {
        let server = LoopbackPeer { _, _ in .none }
        let port = try await server.start()
        let client = Gen1MediaTCPClient(host: "127.0.0.1", port: port, testConfiguration: configuration())
        defer { server.stop() }
        try await client.connect()
        let operation = Task { try await client.fileList() }
        try await Task.sleep(nanoseconds: 60_000_000)
        await client.close()
        do {
            _ = try await operation.value
            throw Failure(description: "closed pending read succeeded")
        } catch is CancellationError { assertions += 1 }
        do {
            _ = try await client.fileList()
            throw Failure(description: "closed connection reused")
        } catch is CancellationError { assertions += 1 }
    }

    static func receiveErrorPreservesDeliveredBytes() async throws {
        for stateFirst in [false, true] {
            let server = LoopbackPeer { command, payload in
                guard command == 1 else { return .none }
                let prefix = response(1, payload + Data(repeating: 7, count: 1_000), external: payload.count).prefix(18 + payload.count)
                return .fragmented(Data(prefix), sizes: [18, payload.count])
            }
            let port = try await server.start()
            let client = Gen1MediaTCPClient(host: "127.0.0.1", port: port, testConfiguration: configuration())
            let root = try directory()
            defer { server.stop(); try? FileManager.default.removeItem(at: root) }
            let destination = root.appendingPathComponent("first.jpg")
            try await client.connect()
            let operation = Task { try await client.downloadFile(named: "first.jpg", to: destination) }
            try await Task.sleep(nanoseconds: 70_000_000)
            let delivered = Data(repeating: 0x91, count: 13)
            let injected = await client.deliverReceiveFailureForTesting(delivered, failStateFirst: stateFirst)
            try check(injected, "file body read ready for data+error fixture")
            do {
                _ = try await operation.value
                throw Failure(description: "receive failure accepted")
            } catch is NWError { assertions += 1 }
            try check(try Data(contentsOf: destination.appendingPathExtension("partial")) == delivered, "content+error preserves delivered bytes, failed state first=\(stateFirst)")
            try check(!FileManager.default.fileExists(atPath: destination.path), "content+error never publishes partial file")
            await client.close()
        }
    }
    #endif
}

#if GEN1_MEDIA_TCP_TESTING
/// Local device fixture. One serial queue protects all callbacks and emitted frames;
/// heartbeat replies are queued between complete frames, never inside a file body.
private final class LoopbackPeer: @unchecked Sendable {
    struct Reply {
        let fragments: [Data]
        let interval: TimeInterval
        let closeAfter: Bool
        static let none = Reply(fragments: [], interval: 0, closeAfter: false)
        static func fragmented(_ data: Data, sizes: [Int], interval: TimeInterval = 0, closeAfter: Bool = false) -> Reply {
            var fragments: [Data] = []
            var offset = 0
            var index = 0
            while offset < data.count {
                let size = min(sizes[index % sizes.count], data.count - offset)
                fragments.append(data.subdata(in: offset..<(offset + size)))
                offset += size
                index += 1
            }
            return Reply(fragments: fragments, interval: interval, closeAfter: closeAfter)
        }
    }
    struct Snapshot { let commands: [UInt16]; let names: [String]; let invalidRequests: Int }
    private let handler: @Sendable (UInt16, Data) -> Reply
    private let queue = DispatchQueue(label: "gen1-media-loopback")
    private var listener: NWListener?
    private var peer: NWConnection?
    private var startup: CheckedContinuation<UInt16, Error>?
    private var input = Data()
    private var commands: [UInt16] = []
    private var names: [String] = []
    private var invalidRequests = 0
    private var replies: [Reply] = []
    private var sending = false

    init(handler: @escaping @Sendable (UInt16, Data) -> Reply) { self.handler = handler }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    self.startup = continuation
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            guard let port = listener.port?.rawValue else { return }
                            let startup = self.startup
                            self.startup = nil
                            startup?.resume(returning: port)
                        case .failed(let error):
                            let startup = self.startup
                            self.startup = nil
                            startup?.resume(throwing: error)
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { connection in
                        self.peer = connection
                        connection.start(queue: self.queue)
                        self.receive()
                    }
                    listener.start(queue: self.queue)
                } catch {
                    self.startup = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.peer?.cancel()
            self.listener = nil
            self.peer = nil
        }
    }

    func snapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Snapshot(commands: self.commands, names: self.names, invalidRequests: self.invalidRequests)) }
        }
    }

    private func receive() {
        peer?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            if let data { self.input.append(data); self.parseInput() }
            if !complete, error == nil { self.receive() }
        }
    }

    private func parseInput() {
        while input.count >= 18 {
            let bytes = [UInt8](input.prefix(18))
            let length = Int(bytes[14]) << 24 | Int(bytes[15]) << 16 | Int(bytes[16]) << 8 | Int(bytes[17])
            guard length >= 20, length <= 65_555 else { invalidRequests += 1; peer?.cancel(); return }
            guard input.count >= length else { return }
            let frame = input.prefix(length)
            let payload = Data(frame.dropFirst(18).dropLast(2))
            let external = Int(bytes[12]) << 8 | Int(bytes[13])
            if bytes[0...3] != [0xAF, 0x8C, 0, 1] || bytes[6...11] != [0, 2, 0, 3, 0, 0]
                || external != payload.count || frame.suffix(2) != Data([0xAF, 0x8C]) { invalidRequests += 1 }
            let command = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            commands.append(command)
            if command == 1 { names.append(String(decoding: payload, as: UTF8.self)) }
            input = Data(input.dropFirst(length))
            let reply = handler(command, payload)
            if !reply.fragments.isEmpty { replies.append(reply); pump() }
        }
    }

    private func pump() {
        guard !sending, !replies.isEmpty else { return }
        sending = true
        send(replies.removeFirst(), index: 0)
    }

    private func send(_ reply: Reply, index: Int) {
        guard index < reply.fragments.count else {
            sending = false
            if reply.closeAfter {
                peer?.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            } else { pump() }
            return
        }
        peer?.send(content: reply.fragments[index], completion: .contentProcessed { error in
            guard error == nil else { return }
            self.queue.asyncAfter(deadline: .now() + reply.interval) { self.send(reply, index: index + 1) }
        })
    }
}
#endif
