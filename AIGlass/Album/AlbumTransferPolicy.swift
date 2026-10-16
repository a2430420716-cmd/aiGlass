import Foundation

/// Per-file transfer budget for photos and videos imported from either generation.
nonisolated enum AlbumTransferPolicy {
    static let fileTimeout: TimeInterval = 3600

    /// Only the end-of-batch network error can be downgraded, after every
    /// listed item has committed to the library. Partial/local failures remain failures.
    static func canReportSavedFilesAfterFinishError(listed: Int, imported: Int,
                                                   failed: Int, recoverableNetworkError: Bool) -> Bool {
        listed > 0 && imported == listed && failed == 0 && recoverableNetworkError
    }
}
