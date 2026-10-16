import Foundation
import UIKit

/// PixSmart 视频防抖 Swift 封装。处理失败返回 false，由导入流程保留原视频。
enum PixSmartVideoEIS {
    /// Explicit entry point prevents a Gen1 import from inheriting Gen2 parameters.
    static func stabilizeGen1Video(from inputURL: URL, to outputURL: URL) async -> Bool {
        try? FileManager.default.removeItem(at: outputURL)
        let cancellation = Gen1VideoCancellation()
        let diagnosticID = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        func logAppState(_ event: String) {
            DebugLogStore.logWiFi("一代：视频防抖运行状态", detail: "processingID=\(diagnosticID) file=\(inputURL.lastPathComponent) event=\(event) elapsedSeconds=\(ProcessInfo.processInfo.systemUptime - started) appState=\(UIApplication.shared.applicationState.rawValue) cancellationRequested=\(cancellation.wasCancelled)")
        }
        logAppState("start")
        let observers = [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
                         UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in logAppState(name.rawValue) }
            }
        }
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                let task = PixSmartVideoStabilizer.stabilizeGen1Video(
                    at: inputURL,
                    outputURL: outputURL,
                    progress: { current, total in
                        guard total > 0, current > 0 else { return }
                        let percent = min(99, current * 100 / total)
                        if cancellation.shouldLogProgress(percent) {
                            DebugLogStore.logWiFi("一代：视频防抖进度", detail: "processingID=\(diagnosticID) percent=\(percent) elapsedSeconds=\(ProcessInfo.processInfo.systemUptime - started) callbackOnMainThread=\(Thread.isMainThread)")
                        }
                    },
                    completion: { success, message in
                        Task { @MainActor in
                            logAppState("completion")
                            DebugLogStore.logWiFi("一代：视频防抖处理结束", detail: "processingID=\(diagnosticID) success=\(success) elapsedSeconds=\(ProcessInfo.processInfo.systemUptime - started) cancellationRequested=\(cancellation.wasCancelled) error=\(message ?? "none") interruptionCause=notInferredFromErrorText")
                            if !success { try? FileManager.default.removeItem(at: outputURL) }
                            continuation.resume(returning: success)
                        }
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
    private var lastLoggedProgress = -10

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func shouldLogProgress(_ percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard percent >= lastLoggedProgress + 10 else { return false }
        lastLoggedProgress = percent
        return true
    }

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
