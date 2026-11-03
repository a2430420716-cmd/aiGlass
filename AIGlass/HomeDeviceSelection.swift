import Foundation

/// Returning home follows a live bound connection. Swiping while already on the
/// home page still selects a new target through the normal connection flow.
enum HomeDeviceSelection {
    /// Promote the live device without changing the relative order of other cards.
    static func connectedFirst<Card>(_ cards: [Card], isConnected: (Card) -> Bool) -> [Card] {
        guard let index = cards.firstIndex(where: isConnected), index > 0 else { return cards }
        var ordered = cards
        let connected = ordered.remove(at: index)
        ordered.insert(connected, at: 0)
        return ordered
    }

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
    private var cardOrder: [String] = []

    mutating func synchronize(to index: Int, cardOrder: [String]) {
        self.index = index
        self.cardOrder = cardOrder
        acceptsUserUpdates = false
    }

    mutating func beginUserScroll() { acceptsUserUpdates = true }

    mutating func receiveVisibleIndex(_ index: Int?, cardOrder: [String]) -> Int? {
        // Reject callbacks from a layout reorder, even before onChange synchronizes it.
        guard acceptsUserUpdates, self.cardOrder == cardOrder,
              let index, cardOrder.indices.contains(index) else { return nil }
        self.index = index
        return index
    }
}
