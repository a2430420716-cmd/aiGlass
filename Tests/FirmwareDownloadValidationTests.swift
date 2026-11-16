import Foundation

@main
enum FirmwareDownloadValidationTests {
    static func main() throws {
        let binary = Data([0x3D, 0xE4, 0x14, 0xD8, 0x1F, 0xEC, 0x62, 0xF8])
        for mime in [nil, "application/octet-stream", "application/x-ufw"] as [String?] {
            try FirmwareDownloadValidation.validate(binary, response: response(mime: mime, length: binary.count))
        }
        try FirmwareDownloadValidation.validate(binary, response: response())

        // Exact response metadata from the post-reboot failure; body reconstructed.
        var html = Data("<!DOCTYPE html><html><body>Gateway</body></html>".utf8)
        html.append(Data(repeating: 0x20, count: 2_578 - html.count))
        expect(.documentResponse, data: html, response: response(mime: "text/html", length: 2_578))
        expect(.documentResponse, data: html, response: response(mime: "application/octet-stream", length: 2_578))
        expect(.documentResponse, data: Data("\u{FEFF} \n<HTML>error</HTML>".utf8), response: response())
        expect(.documentResponse, data: Data(" <!-- gateway -->\n<html>error</html>".utf8), response: response())
        expect(.documentResponse, data: Data("{\"error\":\"unauthorized\"}".utf8), response: response(mime: "application/octet-stream"))
        expect(.documentResponse, data: Data("[{\"error\":1}]".utf8), response: response())
        for mime in ["TEXT/HTML; charset=utf-8", "text/plain", "application/json", "application/problem+json", "application/xml", "application/xhtml+xml"] {
            expect(.documentResponse, data: binary, response: response(mime: mime))
        }
        expect(.documentResponse, data: Data("<?xml version=\"1.0\"?><error/>".utf8), response: response())

        expect(.emptyFile, data: Data(), response: response(length: 0))
        expect(.lengthMismatch, data: binary, response: response(length: binary.count + 1))
        expect(.lengthMismatch, data: binary, response: response(length: binary.count - 1))
        expect(.lengthMismatch, data: binary, response: response(length: 0))
        expect(.lengthMismatch, data: binary, response: response(length: binary.count + 1, encoding: "identity"))
        try FirmwareDownloadValidation.validate(binary, response: response(length: 2, encoding: "gzip"))
        try FirmwareDownloadValidation.validate(binary, response: response(length: 2, encoding: "br"))
        // A binary image can begin with punctuation without being a JSON document.
        try FirmwareDownloadValidation.validate(Data([0x7B, 0xFF, 0x00]), response: response())
        print("Firmware download validation tests passed")
    }

    private static func response(mime: String? = nil, length: Int? = nil, encoding: String? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let mime { headers["Content-Type"] = mime }
        if let length { headers["Content-Length"] = String(length) }
        if let encoding { headers["Content-Encoding"] = encoding }
        return HTTPURLResponse(url: URL(string: "http://example.com/firmware.ufw")!,
                               statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private static func expect(_ error: FirmwareDownloadValidation.ValidationError, data: Data, response: HTTPURLResponse) {
        do {
            try FirmwareDownloadValidation.validate(data, response: response)
            preconditionFailure("Accepted invalid firmware: expected \(error)")
        } catch let actual as FirmwareDownloadValidation.ValidationError {
            precondition(actual == error, "Expected \(error), received \(actual)")
        } catch {
            preconditionFailure("Unexpected validation error: \(error)")
        }
    }
}
