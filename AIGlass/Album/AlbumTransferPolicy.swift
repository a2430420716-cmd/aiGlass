import Foundation

/// Per-file transfer budget for photos and videos imported from either generation.
nonisolated enum AlbumTransferPolicy {
    static let fileTimeout: TimeInterval = 3600
}
