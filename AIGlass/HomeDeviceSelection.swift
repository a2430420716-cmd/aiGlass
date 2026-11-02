import Foundation

/// Returning home follows a live bound connection. Swiping while already on the
/// home page still selects a new target through the normal connection flow.
enum HomeDeviceSelection {
    static func canManageConnection(homeIsVisible: Bool, pairingInProgress: Bool,
                                    hasPresentedPage: Bool) -> Bool {
        homeIsVisible && !pairingInProgress && !hasPresentedPage
    }

    static func keyOnReturn(selected: String?, connected: String?, bound: [String]) -> String? {
        for candidate in [connected, selected].compactMap({ $0 }) {
            if let key = bound.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return key
            }
        }
        return bound.first
    }
}

/// Scroll layout callbacks are not user selections. In particular, the first
/// visible index must not replace the connected device when home is recreated.
struct HomeCarouselSelection {
    private(set) var index: Int?
    private var acceptsUserUpdates = false

    mutating func synchronize(to index: Int) {
        self.index = index
        acceptsUserUpdates = false
    }

    mutating func beginUserScroll() { acceptsUserUpdates = true }

    mutating func receiveVisibleIndex(_ index: Int?) -> Int? {
        guard acceptsUserUpdates, let index else { return nil }
        self.index = index
        return index
    }
}
