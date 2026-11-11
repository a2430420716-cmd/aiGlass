import Foundation
import Network

/// Observes each public API task without changing its routing, timeout or retry policy.
/// Only immutable context is shared with delegate callbacks; NWPathMonitor manages its own queue.
nonisolated final class PublicHTTPDiagnostics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let requestID = String(UUID().uuidString.prefix(8))
    private let endpoint: String
    private let monitor = NWPathMonitor()
    private let startedAt = ProcessInfo.processInfo.systemUptime

    private init(request: URLRequest) {
        endpoint = "\(request.httpMethod ?? "GET") \(request.url?.host ?? "")\(request.url?.path ?? "")"
        super.init()
    }

    static func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let diagnostics = PublicHTTPDiagnostics(request: request)
        diagnostics.start()
        defer { diagnostics.monitor.cancel() }
        do {
            let result = try await session.data(for: request, delegate: diagnostics)
            diagnostics.log("completed", "responseBytes=\(result.0.count)")
            return result
        } catch {
            var chain: [String] = []
            var current: NSError? = error as NSError
            for _ in 0..<4 {
                guard let item = current else { break }
                chain.append("\(item.domain):\(item.code)")
                current = item.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            diagnostics.log("failed", "errorChain=[\(chain.joined(separator: ","))]")
            throw error
        }
    }

    private func start() {
        log("started", "evidence=task_called_not_server_received")
        monitor.pathUpdateHandler = { [weak self] path in
            self?.log("path", "status=\(path.status) usesWiFi=\(path.usesInterfaceType(.wifi))"
                + " usesCellular=\(path.usesInterfaceType(.cellular)) supportsDNS=\(path.supportsDNS)"
                + " supportsIPv4=\(path.supportsIPv4) supportsIPv6=\(path.supportsIPv6)"
                + " expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
                + " evidence=default_path_not_endpoint_reachability")
        }
        monitor.start(queue: DispatchQueue(label: "aiglass.public-http.\(requestID)"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        log("metrics", "transactions=\(metrics.transactionMetrics.count) redirects=\(metrics.redirectCount)"
            + " sentBytes=\(task.countOfBytesSent) receivedBytes=\(task.countOfBytesReceived)")
        for (index, transaction) in metrics.transactionMetrics.enumerated() {
            let milestones = [
                "dnsStart=\(transaction.domainLookupStartDate != nil)",
                "dnsEnd=\(transaction.domainLookupEndDate != nil)",
                "connectStart=\(transaction.connectStartDate != nil)",
                "connectEnd=\(transaction.connectEndDate != nil)",
                "tlsStart=\(transaction.secureConnectionStartDate != nil)",
                "tlsEnd=\(transaction.secureConnectionEndDate != nil)",
                "requestStart=\(transaction.requestStartDate != nil)",
                "requestEnd=\(transaction.requestEndDate != nil)",
                "responseStart=\(transaction.responseStartDate != nil)",
                "responseEnd=\(transaction.responseEndDate != nil)"
            ].joined(separator: " ")
            log("transaction", "index=\(index) protocol=\(transaction.networkProtocolName ?? "unknown")"
                + " reused=\(transaction.isReusedConnection) proxy=\(transaction.isProxyConnection)"
                + " localAddress=\(transaction.localAddress ?? "none") remoteAddress=\(transaction.remoteAddress ?? "none")"
                + " status=\((transaction.response as? HTTPURLResponse)?.statusCode ?? 0) \(milestones)"
                + " dnsMs=\(Self.duration(transaction.domainLookupStartDate, transaction.domainLookupEndDate))"
                + " connectMs=\(Self.duration(transaction.connectStartDate, transaction.connectEndDate))"
                + " tlsMs=\(Self.duration(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate))"
                + " responseWaitMs=\(Self.duration(transaction.requestEndDate, transaction.responseStartDate))"
                + " evidence=observed_metrics_not_proof_of_backend_receipt")
        }
    }

    private static func duration(_ start: Date?, _ end: Date?) -> String {
        guard let start else { return "notObserved" }
        guard let end else { return "incomplete" }
        return String(format: "%.1f", max(0, end.timeIntervalSince(start)) * 1000)
    }

    private func log(_ event: String, _ detail: String) {
        let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - startedAt)
        DebugLogStore.logHTTPEvent("transport \(event)",
            detail: "requestID=\(requestID) endpoint=\(endpoint) elapsedSeconds=\(elapsed) \(detail)")
    }
}
