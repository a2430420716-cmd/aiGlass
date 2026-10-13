import Foundation
@preconcurrency import Network

#if GEN1_MEDIA_TCP_TESTING
/// Loopback testing only. Release builds always require Wi-Fi and production deadlines.
nonisolated struct Gen1MediaTCPTestConfiguration: Sendable {
    var connectTimeout: TimeInterval = 10
    var readIdleTimeout: TimeInterval = 15
    var writeTimeout: TimeInterval = 15
    var fileListTimeout: TimeInterval = 30
    var downloadTimeout: TimeInterval = AlbumTransferPolicy.fileTimeout
    var heartbeatInterval: TimeInterval = 2
}
#endif

/// One sequential batch on the glasses' port 8556. Network callbacks, write queues,
/// heartbeat and operation cancellation are serialized by this actor.
actor Gen1MediaTCPClient {
    private enum State { case idle, connecting, ready, finished, closed }
    private struct Timing {
        var connect: TimeInterval = 10
        var read: TimeInterval = 15
        var write: TimeInterval = 15
        var list: TimeInterval = 30
        var download: TimeInterval = AlbumTransferPolicy.fileTimeout
        var heartbeat: TimeInterval = 2
    }
    private struct WriteRequest {
        let id: UUID
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct ReadRequest {
        let id: UUID
        let maximumLength: Int
        let continuation: CheckedContinuation<Data, Error>
    }

    private let host: String
    private let port: UInt16
    private let requiresWiFi: Bool
    private let timing: Timing
    private let networkQueue = DispatchQueue(label: "com.mocoviso.gen1-media-tcp", qos: .userInitiated)
    private var state = State.idle
    private var connection: NWConnection?
    private var terminalError: Error?
    private var remoteEnded = false
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var connectTimer: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var operationID: UUID?
    private var operationTimer: Task<Void, Never>?
    private var fileTransferActive = false
    private var pendingWrites: [WriteRequest] = []
    private var activeWrite: WriteRequest?
    private var writeTimer: Task<Void, Never>?
    private var pendingRead: ReadRequest?
    private var readTimer: Task<Void, Never>?

    init(host: String, port: UInt16 = 8556) {
        self.host = host
        self.port = port
        requiresWiFi = true
        timing = Timing()
    }

    #if GEN1_MEDIA_TCP_TESTING
    init(host: String, port: UInt16, testConfiguration: Gen1MediaTCPTestConfiguration) {
        self.host = host
        self.port = port
        requiresWiFi = false
        timing = Timing(connect: testConfiguration.connectTimeout, read: testConfiguration.readIdleTimeout,
                        write: testConfiguration.writeTimeout, list: testConfiguration.fileListTimeout,
                        download: testConfiguration.downloadTimeout, heartbeat: testConfiguration.heartbeatInterval)
    }
    #endif

    func connect() async throws {
        if state == .ready {
            if let terminalError { throw terminalError }
            return
        }
        guard state == .idle else { throw terminalError ?? Gen1MediaTCPError.operationInProgress }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw Gen1MediaTCPError.invalidFrame("invalid host or port")
        }
        state = .connecting
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectWaiter = continuation
                let parameters = NWParameters.tcp
                if requiresWiFi { parameters.requiredInterfaceType = .wifi }
                let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    Task { await self?.connectionChanged(state) }
                }
                connectTimer = deadline(after: timing.connect, reason: "连接")
                connection.start(queue: networkQueue)
            }
        } onCancel: {
            Task { await self.abort(CancellationError()) }
        }
    }

    func fileList() async throws -> [String] {
        try await performOperation(timeout: timing.list, reason: "文件列表") {
            try await self.send(.fileList)
            let header = try await self.nextHeader(expected: .fileList)
            guard header.bodyLength <= Gen1MediaTCPProtocol.maxFileListBytes else {
                throw Gen1MediaTCPError.invalidFrame("file list exceeds size limit")
            }
            let body = try await self.readExactly(Int(header.bodyLength))
            try Gen1MediaTCPProtocol.validateTrailer(try await self.readExactly(2))
            return try Gen1MediaTCPProtocol.parseFileList(body)
        }
    }

    /// Receives into `destination.partial`, then publishes a fully verified original
    /// with a same-directory atomic rename. Existing files are never overwritten.
    func downloadFile(named name: String, to destination: URL) async throws -> Int64 {
        let nameBytes = try Gen1MediaTCPProtocol.validateFileName(name)
        guard destination.isFileURL else { throw Gen1MediaTCPError.invalidDestination }
        return try await performOperation(timeout: timing.download, reason: "文件传输", isFileTransfer: true) {
            let file = try Gen1MediaTCPFileSink(destination: destination)
            do {
                try await self.send(.sendFile, payload: nameBytes)
                let header = try await self.nextHeader(expected: .sendFile)
                let expected = try Gen1MediaTCPProtocol.fileLength(header: header, requestedName: nameBytes)
                let returnedName = try await self.readExactly(nameBytes.count)
                guard returnedName == nameBytes else { throw Gen1MediaTCPError.invalidFrame("returned filename differs from request") }
                var received: Int64 = 0
                while received < expected {
                    try Task.checkCancellation()
                    let chunk = try await self.readChunk(maximumLength: Int(min(64 * 1024, expected - received)))
                    // Disk work uses another actor so even a slow write/fsync cannot
                    // block the network actor's heartbeat and cancellation handlers.
                    try await file.write(chunk)
                    received += Int64(chunk.count)
                }
                try Gen1MediaTCPProtocol.validateTrailer(try await self.readExactly(2))
                try Task.checkCancellation()
                try await file.publish(expected: expected)
                return received
            } catch {
                await file.closePreservingPartial()
                throw error
            }
        }
    }

    /// Android's 0x0007 closes the whole batch, not an individual file. It has no ACK.
    func finishTransfer() async throws {
        if state == .finished { return }
        try await performOperation(timeout: timing.write, reason: "传输收尾") {
            self.heartbeatTask?.cancel()
            self.heartbeatTask = nil
            try await self.send(.transferComplete)
            self.state = .finished
        }
    }

    func close() async { abort(CancellationError()) }

    private func performOperation<T>(
        timeout: TimeInterval, reason: String, isFileTransfer: Bool = false,
        _ operation: () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard state == .ready else { throw terminalError ?? Gen1MediaTCPError.notConnected }
        guard operationID == nil else { throw Gen1MediaTCPError.operationInProgress }
        let id = UUID()
        operationID = id
        fileTransferActive = isFileTransfer
        // The file deadline covers request, response and concurrent heartbeats.
        // A heartbeat already being sent must not retain its shorter idle deadline.
        if isFileTransfer {
            writeTimer?.cancel()
            writeTimer = nil
        }
        operationTimer = deadline(after: timeout, reason: reason)
        defer {
            if operationID == id {
                operationID = nil
                operationTimer?.cancel()
                operationTimer = nil
                fileTransferActive = false
                // Restore the control-write deadline if a heartbeat outlives this file.
                if isFileTransfer, state == .ready, activeWrite != nil {
                    writeTimer = deadline(after: timing.write, reason: "数据发送")
                }
            }
        }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await operation()
            } onCancel: {
                Task { await self.cancelOperation(id) }
            }
        } catch {
            abort(error)
            throw error
        }
    }

    private func cancelOperation(_ id: UUID) {
        guard operationID == id else { return }
        abort(CancellationError())
    }

    private func connectionChanged(_ newState: NWConnection.State) {
        guard state != .closed else { return }
        switch newState {
        case .ready:
            guard state == .connecting else { return }
            state = .ready
            connectTimer?.cancel()
            connectTimer = nil
            let waiter = connectWaiter
            connectWaiter = nil
            waiter?.resume()
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let interval = await self?.heartbeatInterval() else { return }
                    do { try await Task.sleep(nanoseconds: Self.nanoseconds(interval)) } catch { return }
                    guard !Task.isCancelled else { return }
                    await self?.sendHeartbeat()
                }
            }
        case .failed(let error): transportFailed(error)
        case .cancelled: transportFailed(Gen1MediaTCPError.connectionClosed)
        default: break // A waiting route gets the same bounded connect deadline.
        }
    }

    private func heartbeatInterval() -> TimeInterval? { state == .ready ? timing.heartbeat : nil }

    private func sendHeartbeat() async {
        guard state == .ready, !Task.isCancelled else { return }
        do { try await send(.heartbeat) } catch { transportFailed(error) }
    }

    private func send(_ command: Gen1MediaTCPCommand, payload: Data = Data()) async throws {
        if let terminalError { throw terminalError }
        guard state == .ready, connection != nil else { throw terminalError ?? Gen1MediaTCPError.notConnected }
        let data = try Gen1MediaTCPProtocol.request(command, payload: payload)
        try await withCheckedThrowingContinuation { continuation in
            pendingWrites.append(WriteRequest(id: UUID(), data: data, continuation: continuation))
            pumpWrite()
        }
    }

    private func pumpWrite() {
        guard activeWrite == nil, !pendingWrites.isEmpty, let connection, state == .ready else { return }
        let request = pendingWrites.removeFirst()
        activeWrite = request
        if !fileTransferActive {
            writeTimer = deadline(after: timing.write, reason: "数据发送")
        }
        connection.send(content: request.data, completion: .contentProcessed { [weak self] error in
            Task { await self?.writeCompleted(id: request.id, error: error) }
        })
    }

    private func writeCompleted(id: UUID, error: NWError?) {
        guard let request = activeWrite, request.id == id else { return }
        if let error { transportFailed(error); return }
        writeTimer?.cancel()
        writeTimer = nil
        activeWrite = nil
        request.continuation.resume()
        pumpWrite()
    }

    private func nextHeader(expected: Gen1MediaTCPCommand) async throws -> Gen1MediaTCPHeader {
        while true {
            let header = try Gen1MediaTCPProtocol.parseResponseHeader(try await readExactly(18))
            if header.command == Gen1MediaTCPCommand.heartbeat.rawValue {
                guard header.bodyLength <= Gen1MediaTCPProtocol.maxHeartbeatBytes else {
                    throw Gen1MediaTCPError.invalidFrame("heartbeat response exceeds size limit")
                }
                _ = try await readExactly(Int(header.bodyLength))
                try Gen1MediaTCPProtocol.validateTrailer(try await readExactly(2))
                continue
            }
            guard header.command == expected.rawValue else { throw Gen1MediaTCPError.unexpectedCommand(header.command) }
            return header
        }
    }

    private func readExactly(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw Gen1MediaTCPError.invalidFrame("negative read size") }
        var result = Data(capacity: count)
        while result.count < count {
            try Task.checkCancellation()
            result.append(try await readChunk(maximumLength: min(64 * 1024, count - result.count)))
        }
        return result
    }

    private func readChunk(maximumLength: Int) async throws -> Data {
        guard state == .ready, connection != nil else { throw terminalError ?? Gen1MediaTCPError.notConnected }
        guard !remoteEnded else { throw terminalError ?? Gen1MediaTCPError.connectionClosed }
        guard pendingRead == nil else { throw Gen1MediaTCPError.operationInProgress }
        return try await withCheckedThrowingContinuation { continuation in
            let request = ReadRequest(id: UUID(), maximumLength: maximumLength, continuation: continuation)
            pendingRead = request
            if !fileTransferActive {
                readTimer = deadline(after: timing.read, reason: "数据接收")
            }
            receive(request)
        }
    }

    private func receive(_ request: ReadRequest) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: request.maximumLength) { [weak self] data, _, complete, error in
            Task { await self?.received(id: request.id, data: data, complete: complete, error: error) }
        }
    }

    private func received(id: UUID, data: Data?, complete: Bool, error: NWError?) {
        guard let request = pendingRead, request.id == id else { return }
        if let data, !data.isEmpty {
            // Network.framework may return content and an error together. Deliver
            // all content first so file bytes reach .partial; fail the next read.
            if let error { terminalError = error }
            remoteEnded = complete || terminalError != nil
            readTimer?.cancel()
            readTimer = nil
            pendingRead = nil
            request.continuation.resume(returning: data)
        } else if let error {
            abort(error)
        } else if complete || terminalError != nil {
            abort(terminalError ?? Gen1MediaTCPError.connectionClosed)
        } else {
            // Empty callbacks do not count as progress and do not extend the idle timer.
            receive(request)
        }
    }

    private func deadline(after seconds: TimeInterval, reason: String) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.nanoseconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.abort(Gen1MediaTCPError.timeout(reason))
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0.001, min(seconds, 86_400)) * 1_000_000_000)
    }

    private func transportFailed(_ error: Error) {
        guard state != .closed else { return }
        guard pendingRead != nil else { abort(error); return }
        // State/error callbacks can precede the receive callback carrying the last
        // bytes. Leave that single read alive under its existing bounded deadline.
        terminalError = error
        remoteEnded = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        failWrites(error)
    }

    private func failWrites(_ error: Error) {
        writeTimer?.cancel()
        writeTimer = nil
        let writing = activeWrite
        activeWrite = nil
        writing?.continuation.resume(throwing: error)
        let queued = pendingWrites
        pendingWrites.removeAll()
        queued.forEach { $0.continuation.resume(throwing: error) }
    }

    #if GEN1_MEDIA_TCP_TESTING
    /// Deterministic coverage for Network.framework's documented data+error callback.
    func deliverReceiveFailureForTesting(_ bytes: Data, failStateFirst: Bool) -> Bool {
        guard let pendingRead else { return false }
        let error = NWError.posix(.ECONNRESET)
        if failStateFirst { connectionChanged(.failed(error)) }
        received(id: pendingRead.id, data: bytes, complete: false, error: error)
        return true
    }
    #endif

    private func abort(_ error: Error) {
        guard state != .closed else { return }
        state = .closed
        terminalError = error
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        [connectTimer, readTimer, writeTimer, operationTimer, heartbeatTask].forEach { $0?.cancel() }
        connectTimer = nil
        readTimer = nil
        writeTimer = nil
        operationTimer = nil
        heartbeatTask = nil
        let connecting = connectWaiter
        connectWaiter = nil
        connecting?.resume(throwing: error)
        let reading = pendingRead
        pendingRead = nil
        reading?.continuation.resume(throwing: error)
        failWrites(error)
    }
}

/// Keeps synchronous filesystem calls off the network actor. The final name is the
/// durable completion marker used by the import coordinator's crash recovery journal.
private actor Gen1MediaTCPFileSink {
    private let destination: URL
    private let partial: URL
    private var handle: FileHandle?
    private var written: UInt64 = 0

    init(destination: URL) throws {
        self.destination = destination
        partial = destination.appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try Data().write(to: partial, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: partial)
    }

    func write(_ data: Data) throws {
        guard let handle else { throw Gen1MediaTCPError.invalidDestination }
        try handle.write(contentsOf: data)
        written += UInt64(data.count)
    }

    func publish(expected: Int64) throws {
        guard let handle else { throw Gen1MediaTCPError.invalidDestination }
        try handle.synchronize()
        let actual = try handle.seekToEnd()
        guard actual == UInt64(expected), written == UInt64(expected) else {
            throw Gen1MediaTCPError.invalidFrame("saved file length differs from frame")
        }
        try handle.close()
        self.handle = nil
        try Task.checkCancellation()
        // Same parent/filesystem permits atomic rename. Existing destinations are
        // refused, including files that appeared after the original existence check.
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    func closePreservingPartial() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}
