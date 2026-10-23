import Foundation

/// Returning home follows a live bound connection. Swiping while already on the
/// home page still selects a new target through the normal connection flow.
enum HomeDeviceSelection {
    static func keyOnReturn(selected: String?, connected: String?, bound: [String]) -> String? {
        for candidate in [connected, selected].compactMap({ $0 }) {
            if let key = bound.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return key
            }
        }
        return bound.first
    }
}
