import Foundation

@main
struct Gen1VideoImportTests {
    @MainActor static var checks = 0
    enum TestError: Error { case exportFailed }

    @MainActor static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
        checks += 1
        let result = try value()
        precondition(result, message)
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.mp4")
        let enhanced = root.appendingPathComponent("enhanced.mp4")
        let output = root.appendingPathComponent("album.mp4")
        let originalData = Data("unmodified video and audio".utf8)
        try originalData.write(to: source)
        var calls: [String] = []

        let success = try await Gen1VideoImportPipeline.process(
            source: source, stabilizedURL: enhanced, output: output,
            stabilize: { input, destination in
                expect(input == source && destination == enhanced, "SDK receives unrotated preserved original")
                calls.append("stabilize")
                try! Data("stabilized video only".utf8).write(to: destination)
                return true
            },
            rotateWithAudio: { video, audio, destination in
                expect(video == enhanced, "Successful SDK video used")
                expect(audio == source, "Audio restored from original, not silent SDK output")
                expect(destination == output, "Final derivative separate from source")
                calls.append("rotate-and-mux")
                try Data("rotated video and original audio".utf8).write(to: destination)
            }
        )
        expect(success == .stabilized && calls == ["stabilize", "rotate-and-mux"], "Stabilize before exactly one orientation correction")
        try expect(Data(contentsOf: source) == originalData, "Success never alters archive")
        expect(!FileManager.default.fileExists(atPath: enhanced.path), "Temporary SDK output cleaned after success")
        try expect(Data(contentsOf: output) == Data("rotated video and original audio".utf8), "Final derivative retained")

        calls = []
        let fallback = try await Gen1VideoImportPipeline.process(
            source: source, stabilizedURL: enhanced, output: output,
            stabilize: { _, destination in
                try! Data("partial native output".utf8).write(to: destination)
                return false
            },
            rotateWithAudio: { video, audio, destination in
                expect(video == source && audio == source, "SDK failure uses original picture and audio")
                expect(!FileManager.default.fileExists(atPath: destination.path), "No stale derivative on fallback")
                calls.append("fallback")
                try originalData.write(to: destination)
            }
        )
        expect(fallback == .originalFallback && calls == ["fallback"], "License/init/processing failure may still import original")
        expect(!FileManager.default.fileExists(atPath: enhanced.path), "Failed SDK derivative removed")
        try expect(Data(contentsOf: source) == originalData, "Native failure preserves source")

        var rotations = 0
        var diagnostics: [String] = []
        let muxFallback = try await Gen1VideoImportPipeline.process(
            source: source, stabilizedURL: enhanced, output: output,
            stabilize: { _, destination in try! originalData.write(to: destination); return true },
            rotateWithAudio: { video, audio, destination in
                rotations += 1
                expect(audio == source, "Both mux attempts use original audio")
                if rotations == 1 {
                    expect(video == enhanced, "Try enhanced video first")
                    try Data("broken export".utf8).write(to: destination)
                    throw TestError.exportFailed
                }
                expect(video == source, "Invalid enhanced export falls back to source")
                expect(!FileManager.default.fileExists(atPath: destination.path), "Partial enhanced export removed before retry")
                try originalData.write(to: destination)
            },
            diagnostic: { diagnostics.append($0) }
        )
        expect(muxFallback == .originalFallback && rotations == 2, "Mux failure falls back once")
        expect(diagnostics.count == 1, "Fallback reason reported")
        try expect(Data(contentsOf: source) == originalData, "Mux failure preserves source")

        do {
            _ = try await Gen1VideoImportPipeline.process(
                source: source, stabilizedURL: enhanced, output: output,
                stabilize: { _, _ in false },
                rotateWithAudio: { _, _, _ in throw TestError.exportFailed }
            )
            preconditionFailure("Failed original export must not be successful import")
        } catch TestError.exportFailed { expect(true, "Original export failure propagated for inbox recovery") }
        try expect(Data(contentsOf: source) == originalData, "Complete failure preserves archive")

        var rotatedAfterCancellation = false
        let cancelled = Task { @MainActor in
            try await Gen1VideoImportPipeline.process(
                source: source, stabilizedURL: enhanced, output: output,
                stabilize: { _, destination in
                    try! originalData.write(to: destination)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                },
                rotateWithAudio: { _, _, _ in rotatedAfterCancellation = true }
            )
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancellation ignored") }
        catch is CancellationError { expect(true, "Cancellation propagated after native callback") }
        expect(!rotatedAfterCancellation, "Cancelled pipeline does not save a derivative")
        expect(!FileManager.default.fileExists(atPath: enhanced.path), "Cancelled pipeline cleans only temporary SDK output")
        try expect(Data(contentsOf: source) == originalData, "Cancellation retains original")

        let alias = root.appendingPathComponent("source-alias.mp4")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        for badOutput in [source, alias, enhanced] {
            do {
                _ = try await Gen1VideoImportPipeline.process(
                    source: source, stabilizedURL: enhanced, output: badOutput,
                    stabilize: { _, _ in preconditionFailure("Overlapping path reached SDK") },
                    rotateWithAudio: { _, _, _ in preconditionFailure("Overlapping path reached export") }
                )
                preconditionFailure("Overlapping paths accepted")
            } catch Gen1VideoImportPipeline.Failure.overlappingPaths {
                expect(true, "Overlapping source/derivative path rejected")
            }
        }
        try expect(Data(contentsOf: source) == originalData, "No overlapping-path deletion")
        print("Gen1 video import: \(checks) assertions passed")
    }
}
