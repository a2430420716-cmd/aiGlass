import Foundation
import Network

@main
@MainActor
enum GlassesHTTPUploadResponseTests {
    private typealias Response = GlassesHTTPUploadResponse
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    static func main() {
        completedSendAllowsOnlyKnownDisconnectErrors()
        incompleteOrCancelledSendCannotUseCompatibility()
        observedRejectionAlwaysWins()
        statusLineMayBeFragmentedAtEveryByte()
        informationalResponsesDoNotHideFinalStatus()
        malformedOrTruncatedResponsesCannotUseCompatibility()
        responseBufferHasABound()
        check(nonisolatedUseCompiles(), "Upload response handling must work off MainActor")
        print("Glasses HTTP upload response: \(assertions) assertions passed")
    }

    private static func outcome(
        _ response: Response,
        error: NWError = .posix(.ECONNRESET),
        completed: Bool = true,
        bytes: Int = 4096,
        cancelled: Bool = false
    ) -> Response.Outcome? {
        response.outcomeAfterConnectionError(
            error, bodySendCompleted: completed, totalBytes: bytes, cancelled: cancelled
        )
    }

    private static func completedSendAllowsOnlyKnownDisconnectErrors() {
        let response = Response()
        for code in [POSIXErrorCode.ECONNRESET, .ECONNABORTED, .EPIPE] {
            let result = outcome(response, error: .posix(code))
            check(result == .connectionClosedAfterUpload(code.rawValue),
                  "Complete local send may continue for \(code), while device result remains required")
            check(result?.statusCode == nil, "Compatibility must never invent an HTTP status")
        }
        for code in [POSIXErrorCode.ETIMEDOUT, .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH,
                     .ECONNREFUSED, .ECANCELED, .EACCES, .ENOTCONN] {
            check(outcome(response, error: .posix(code)) == nil,
                  "Unverified upload cannot continue for \(code)")
        }
        check(outcome(response, error: .dns(-65554)) == nil, "DNS errors cannot mean upload accepted")
        check(outcome(response, error: .tls(-9806)) == nil, "TLS errors cannot mean upload accepted")
    }

    private static func incompleteOrCancelledSendCannotUseCompatibility() {
        let response = Response()
        for code in [POSIXErrorCode.ECONNRESET, .ECONNABORTED, .EPIPE] {
            check(outcome(response, error: .posix(code), completed: false) == nil,
                  "Partial or failed local send must reject \(code)")
            check(outcome(response, error: .posix(code), cancelled: true) == nil,
                  "Cancellation takes precedence over \(code)")
            check(outcome(response, error: .posix(code), bytes: 0) == nil,
                  "An empty payload cannot use compatibility")
            check(outcome(response, error: .posix(code), bytes: -1) == nil,
                  "Unknown or invalid payload size cannot use compatibility")
        }
        var statusReceived = Response()
        check(statusReceived.append(Data("HTTP/1.1 200 OK\r\n".utf8)) == .status(200),
              "A final status is recognized")
        check(outcome(statusReceived, cancelled: true) == nil,
              "Cancellation still wins if a final status has arrived")
    }

    private static func observedRejectionAlwaysWins() {
        for code in [301, 400, 404, 413, 500, 503] {
            var response = Response()
            check(response.append(Data("HTTP/1.1 \(code) Rejected\r\nContent-Length: 0\r\n\r\n".utf8)) == .status(code),
                  "Server rejection \(code) must be observed")
            for error in [POSIXErrorCode.ECONNRESET, .ECONNABORTED, .EPIPE, .ETIMEDOUT] {
                check(outcome(response, error: .posix(error)) == .httpStatus(code),
                      "\(error) must not replace HTTP \(code) with compatibility")
            }
            check(response.append(Data("HTTP/1.1 200 OK\r\n".utf8)) == .status(code),
                  "A later buffer must not overwrite a recorded rejection")
        }
    }

    private static func statusLineMayBeFragmentedAtEveryByte() {
        let message = Data("HTTP/1.1 503 Service Unavailable\r\n".utf8)
        for split in 1..<message.count {
            var response = Response()
            check(response.append(Data(message.prefix(split))) == .pending,
                  "Split \(split) must wait for the complete status line")
            check(outcome(response) == nil, "A partial status line followed by reset must fail")
            check(response.append(Data(message.dropFirst(split))) == .status(503),
                  "Split \(split) must reassemble the status line")
            check(outcome(response) == .httpStatus(503), "Reassembled rejection must survive reset")
        }
        var oneByteAtATime = Response()
        let ok = Array("HTTP/1.0 204 No Content\r\n".utf8)
        for (index, byte) in ok.enumerated() {
            check(oneByteAtATime.append(Data([byte])) == (index == ok.count - 1 ? .status(204) : .pending),
                  "One-byte TCP fragments must remain valid")
        }
    }

    private static func informationalResponsesDoNotHideFinalStatus() {
        let final = "HTTP/1.1 500 Failed\r\nContent-Length: 0\r\n\r\n"
        let message = Data(("HTTP/1.1 100 Continue\r\n\r\n"
            + "HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n" + final).utf8)
        let finalLineEnd = message.count - Data("Content-Length: 0\r\n\r\n".utf8).count
        for split in 0...finalLineEnd {
            var response = Response()
            let first = response.append(Data(message.prefix(split)))
            check(first == (split == finalLineEnd ? .status(500) : .pending),
                  "Informational responses must not count as final success")
            check(response.append(Data(message.dropFirst(split))) == .status(500),
                  "Coalesced or fragmented informational responses must preserve final 500")
            check(outcome(response) == .httpStatus(500), "100 then 500 then reset must fail as HTTP 500")
        }
        var interimOnly = Response()
        check(interimOnly.append(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) == .pending,
              "100 Continue requires a final response")
        check(outcome(interimOnly) == nil, "A reset after only an informational response is an incomplete response")
    }

    private static func malformedOrTruncatedResponsesCannotUseCompatibility() {
        for line in ["garbage\r\n", "HTTP/2 200 OK\r\n", "HTTP/1.1 x00 Bad\r\n",
                     "HTTP/1.1 20 Bad\r\n", "HTTP/1.1 099 Bad\r\n", "HTTP/1.1 600 Bad\r\n",
                     "HTTP/1.1 101 Switching Protocols\r\n\r\n", "\r\n"] {
            var response = Response()
            check(response.append(Data(line.utf8)) == .invalid, "Malformed response must be invalid: \(line)")
            check(outcome(response) == nil, "Malformed response plus reset must not use compatibility")
            check(response.append(Data("HTTP/1.1 200 OK\r\n".utf8)) == .invalid,
                  "A malformed response must remain invalid")
        }
        for partial in ["H", "HTTP/1.1 ", "HTTP/1.1 500 Failed\r", "HTTP/1.1 100 Continue\r\nX: a\r\n"] {
            var response = Response()
            check(response.append(Data(partial.utf8)) == .pending, "Incomplete response must wait for more bytes")
            check(outcome(response) == nil, "Truncated response must not become a successful reset")
        }
    }

    private static func responseBufferHasABound() {
        var response = Response()
        check(response.append(Data(repeating: 65, count: 64 * 1024)) == .pending,
              "An incomplete response at the buffer limit waits")
        check(response.append(Data([65])) == .invalid, "A growing incomplete header must be bounded")
        check(outcome(response) == nil, "Oversized response must not use reset compatibility")
        var informational = Response()
        let largeHeader = Data(("HTTP/1.1 100 Continue\r\nX: " + String(repeating: "a", count: 32768) + "\r\n\r\n").utf8)
        check(informational.append(largeHeader) == .pending, "One informational header may fit")
        check(informational.append(largeHeader) == .invalid, "Discarded informational bytes count toward the bound")
    }

    nonisolated private static func nonisolatedUseCompiles() -> Bool {
        var response = Response()
        return response.append(Data("HTTP/1.1 200 OK\r\n".utf8)) == .status(200)
    }
}
