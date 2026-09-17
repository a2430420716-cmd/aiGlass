import Foundation

enum FirmwareVersionComparator {
    /// 服务端版本是否高于设备/App 当前版本（App 更新提示用）。
    static func isServerVersionNewer(_ server: String, than device: String) -> Bool {
        guard let serverParts = parseNumericVersion(server),
              let deviceParts = parseNumericVersion(device) else {
            return false
        }
        return compare(serverParts, deviceParts) > 0
    }

    /// 数字版本是否不同；无法解析时不误报。
    static func areVersionsDifferent(_ local: String, _ server: String) -> Bool {
        guard let localParts = parseNumericVersion(local),
              let serverParts = parseNumericVersion(server) else {
            return false
        }
        return compare(localParts, serverParts) != 0
    }

    private static func compare(_ left: [Int], _ right: [Int]) -> Int {
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l == r { continue }
            return l < r ? -1 : 1
        }
        return 0
    }

    /// 对齐 Android `VersionParts.parse`：提取首个 2~4 段纯数字版本，忽略 V 前缀和构建后缀。
    private static func parseNumericVersion(_ version: String) -> [Int]? {
        let range = NSRange(version.startIndex..<version.endIndex, in: version)
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+){1,3}"#),
              let match = regex.firstMatch(in: version, range: range),
              let swiftRange = Range(match.range, in: version) else {
            return nil
        }
        let parts = version[swiftRange].split(separator: ".").compactMap { Int($0) }
        return parts.count >= 2 ? parts : nil
    }
}
