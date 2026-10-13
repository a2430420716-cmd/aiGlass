import Foundation
import Network

/// A missing response after a complete local send is an Android compatibility path,
/// not evidence that the glasses accepted the file or finished upgrading.
nonisolated struct GlassesHTTPUploadResponse {
    enum Outcome: Equatable, Sendable {
        case httpStatus(Int)
        case connectionClosedAfterUpload(Int32)

        var statusCode: Int? {
            if case .httpStatus(let code) = self { return code }
            return nil
        }
    }

    enum ParseResult: Equatable {
        case pending
        case status(Int)
        case invalid
    }

    private var buffer = Data()
    private var headerBytes = 0
    private(set) var statusCode: Int?
    private(set) var invalid = false

    /// TCP may split the status line, or coalesce an informational and final response.
    mutating func append(_ data: Data) -> ParseResult {
        if invalid { return .invalid }
        if let statusCode { return .status(statusCode) }
        buffer.append(data)
        let crlf = Data([13, 10])
        let headerEnd = Data([13, 10, 13, 10])
        while let lineEnd = buffer.range(of: crlf) {
            let line = String(decoding: buffer[..<lineEnd.lowerBound], as: UTF8.self)
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[0])),
                  parts[1].count == 3, let code = Int(parts[1]), (100...599).contains(code) else {
                invalid = true
                return .invalid
            }
            if code >= 200 {
                statusCode = code
                return .status(code)
            }
            // Protocol switching is not a valid response to a firmware PUT.
            guard code != 101 else {
                invalid = true
                return .invalid
            }
            guard let end = buffer.range(of: headerEnd) else { break }
            headerBytes += buffer.distance(from: buffer.startIndex, to: end.upperBound)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        }
        if headerBytes + buffer.count > 64 * 1024 {
            invalid = true
            return .invalid
        }
        return .pending
    }

    func outcomeAfterConnectionError(
        _ error: NWError,
        bodySendCompleted: Bool,
        totalBytes: Int,
        cancelled: Bool
    ) -> Outcome? {
        guard !cancelled else { return nil }
        // Never let a reset replace an observed rejection with compatibility success.
        if let statusCode { return .httpStatus(statusCode) }
        guard !invalid, headerBytes == 0, buffer.isEmpty, bodySendCompleted, totalBytes > 0,
              case .posix(let code) = error,
              [.ECONNRESET, .ECONNABORTED, .EPIPE].contains(code) else { return nil }
        return .connectionClosedAfterUpload(code.rawValue)
    }
}
