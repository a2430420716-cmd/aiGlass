import Foundation

enum DeviceIdentityPresentation {
    /// A cached Bluetooth identifier must never masquerade as a hardware serial number.
    static func hardwareSN(candidates: [String?], bluetoothID: String?) -> String? {
        let identifier = bluetoothID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { value in
                !value.isEmpty
                    && value.caseInsensitiveCompare(identifier ?? "") != .orderedSame
                    && UUID(uuidString: value) == nil
                    && value.range(of: "^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$", options: .regularExpression) == nil
            }
    }
}
