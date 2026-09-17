import Foundation

/// PixSmart 视频防抖 Swift 封装。处理失败返回 false，由导入流程保留原视频。
enum PixSmartVideoEIS {
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
