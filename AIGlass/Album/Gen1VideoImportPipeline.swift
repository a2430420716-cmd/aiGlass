import Foundation

/// Keep the archived source untouched while trying stabilization, audio restoration
/// and rotation. Android also falls back to original media if enhancement fails.
@MainActor
enum Gen1VideoImportPipeline {
    enum Result: Equatable {
        case stabilized
        case originalFallback
        case unreadableOriginal
        case unprocessedOriginal
    }

    enum Failure: Error {
        case overlappingPaths
    }

    static func process(
        source: URL,
        stabilizedURL: URL,
        output: URL,
        originalIsReadable: Bool = true,
        stabilize: (URL, URL) async -> Bool,
        rotateWithAudio: (URL, URL, URL) async throws -> Void,
        diagnostic: (String) -> Void = { _ in }
    ) async throws -> Result {
        let paths = [source, stabilizedURL, output].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard Set(paths).count == 3 else { throw Failure.overlappingPaths }
        try Task.checkCancellation()
        defer { try? FileManager.default.removeItem(at: stabilizedURL) }

        if !originalIsReadable {
            // Transfer integrity and playback support are separate. Save the
            // completed file unchanged; native enhancement cannot read it.
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: source, to: output)
            try Task.checkCancellation()
            return .unreadableOriginal
        }

        let enhanced = await stabilize(source, stabilizedURL)
        try Task.checkCancellation()
        if enhanced {
            do {
                try await rotateWithAudio(stabilizedURL, source, output)
                try Task.checkCancellation()
                return .stabilized
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                diagnostic("Stabilized video could not be finalized: \(error.localizedDescription)")
            }
        } else {
            diagnostic("Stabilization unavailable or failed; using preserved original")
        }

        // Failed export may have left a partial derivative. Only remove that output,
        // never the source archive or its inbox entry.
        try? FileManager.default.removeItem(at: output)
        do {
            try await rotateWithAudio(source, source, output)
            try Task.checkCancellation()
            return .originalFallback
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            diagnostic("Original export failed; saving downloaded bytes unchanged: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: source, to: output)
            try Task.checkCancellation()
            return .unprocessedOriginal
        }
    }
}
