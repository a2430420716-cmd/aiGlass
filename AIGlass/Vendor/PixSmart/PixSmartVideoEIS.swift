import Foundation

/// PixSmart 视频防抖 Swift 封装。处理失败返回 false，由导入流程保留原视频。
enum PixSmartVideoEIS {
    /// Explicit entry point prevents a Gen1 import from inheriting Gen2 parameters.
    static func stabilizeGen1Video(from inputURL: URL, to outputURL: URL) async -> Bool {
        try? FileManager.default.removeItem(at: outputURL)
        let cancellation = Gen1VideoCancellation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                let task = PixSmartVideoStabilizer.stabilizeGen1Video(
                    at: inputURL,
                    outputURL: outputURL,
                    progress: { current, total in
                        guard total > 0, current > 0 else { return }
                        let percent = min(99, current * 100 / total)
                        if percent % 10 == 0 { print("[PixSmartVideoEIS] gen1 progress \(percent)%") }
                    },
                    completion: { success, message in
                        DebugLogStore.logWiFi("一代：视频防抖处理结束", detail: "success=\(success) error=\(message ?? "none")")
                        if !success { try? FileManager.default.removeItem(at: outputURL) }
                        continuation.resume(returning: success)
                    }
                )
                cancellation.install(task)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func stabilizeVideo(from inputURL: URL, to outputURL: URL) async -> Bool {
        try? FileManager.default.removeItem(at: outputURL)

        return await withCheckedContinuation { continuation in
            PixSmartVideoStabilizer.stabilizeVideo(
                at: inputURL,
                outputURL: outputURL,
                progress: { current, total in
                    guard total > 0, current > 0 else { return }
                    let percent = min(99, current * 100 / total)
                    if percent % 10 == 0 {
                        print("[PixSmartVideoEIS] progress \(current)/\(total) \(percent)%")
                    }
                },
                completion: { success, errorMessage in
                    if success {
                        print("[PixSmartVideoEIS] processing succeeded")
                    } else {
                        print("[PixSmartVideoEIS] fallback to original: \(errorMessage ?? "unknown error")")
                        try? FileManager.default.removeItem(at: outputURL)
                    }
                    continuation.resume(returning: success)
                }
            )
        }
    }
}

/// Cancellation can race the Objective-C method returning its handle.
/// Remember it until installation so neither ordering loses the stop request.
nonisolated private final class Gen1VideoCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: PixSmartVideoStabilizationTask?
    private var isCancelled = false

    func install(_ task: PixSmartVideoStabilizationTask) {
        lock.lock()
        self.task = task
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}
