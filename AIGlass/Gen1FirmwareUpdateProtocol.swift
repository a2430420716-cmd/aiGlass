import Foundation

struct Gen1FirmwareWifiCredentials {
    let ssid: String
    let password: String
}

/// 3303 firmware downloads the image itself using an unauthenticated HTTP GET.
enum Gen1FirmwareUpdateProtocol {
    static let minimumBatteryPercent = 80

    static func wifiPayload(ssid: String, password: String) throws -> Data {
        let trimmedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty else { throw ValidationError.emptySSID }
        let ssidBytes = Data(trimmedSSID.utf8)
        let passwordBytes = Data(password.utf8)
        guard ssidBytes.count <= 127, passwordBytes.count <= 127 else {
            throw ValidationError.wifiFieldTooLong
        }
        // Match Android/vendor encoding, including UTF-8 SSIDs and open networks.
        return ssidBytes + Data([0x2F]) + passwordBytes
    }

    static func urlPayload(_ rawURL: String, trustedBaseURL: URL? = nil) throws -> Data {
        var value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("https://"),
           let host = URLComponents(string: value)?.host,
           let trustedHost = trustedBaseURL?.host,
           !trustedHost.isEmpty,
           host.caseInsensitiveCompare(trustedHost) == .orderedSame {
            // Only the application's own server is known to serve the same file
            // over HTTP. Preserve its path/query bytes exactly when changing scheme.
            value = "http://" + value.dropFirst("https://".count)
        }
        guard value.hasPrefix("http://"),
              let components = URLComponents(string: value),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw ValidationError.invalidURL
        }
        guard value.utf8.allSatisfy({ (0x21...0x7E).contains($0) }), value.utf8.count < 16_384 else {
            throw ValidationError.invalidCharacters
        }
        return Data([1]) + Data(value.utf8)
    }

    static func batteryLevel(reported: Int?, baseline: Int?) -> Int? {
        // Android stabilizes a transient low read against the pre-query snapshot.
        // Discard malformed readings instead of allowing them to pass the gate.
        [reported, baseline].compactMap { $0 }.filter { (0...100).contains($0) }.max()
    }

    static func progress(command: UInt8, payload: Data) -> Int? {
        guard command == 0x3A || command == 0x18,
              let byte = payload.first, byte <= 100 else { return nil }
        return Int(byte)
    }

    static func versionsMatch(_ actual: String, target: String) -> Bool {
        func normalize(_ value: String) -> String {
            let stripped = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
            // Android extracts the first numeric version from strings such as
            // "G5K61_1.02.3_20250901" before comparing it with the server version.
            let numericRange = stripped.range(of: #"\d+(?:\.\d+){1,3}"#, options: .regularExpression)
            let numeric = numericRange.map { String(stripped[$0]) } ?? stripped
            let parts = numeric.split(separator: ".").map { String(Int($0) ?? -1) }
            if parts.contains("-1") { return stripped.lowercased() }
            return parts.joined(separator: ".")
        }
        return !actual.isEmpty && !target.isEmpty && normalize(actual) == normalize(target)
    }

    enum ValidationError: LocalizedError {
        case invalidURL
        case invalidCharacters
        case emptySSID
        case wifiFieldTooLong

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "一代固件升级地址必须为无需认证的 HTTP 链接，设备不支持 HTTPS"
            case .invalidCharacters:
                return "一代固件升级地址必须为有效长度的纯 ASCII 字符，不可包含空格或中文"
            case .emptySSID:
                return "请输入眼镜连接的 Wi-Fi 名称"
            case .wifiFieldTooLong:
                return "Wi-Fi 名称和密码各不能超过 127 个 UTF-8 字节"
            }
        }
    }
}
