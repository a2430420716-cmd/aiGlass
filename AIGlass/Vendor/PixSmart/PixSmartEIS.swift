import Foundation

/// PixSmart 纯图像 EIS 封装：眼镜导入照片后做防抖。
/// 模拟器 / 鉴权失败 / 处理失败时原样返回，不阻断导入。
enum PixSmartEIS {
    static var isAvailable: Bool {
        PixSmartImageStabilizer.isAvailable()
    }

    /// 有公网时调用一次完成设备激活（避免连眼镜热点后出现 -21）。
    @discardableResult
    static func prewarmLicense() -> Bool {
        let ok = PixSmartImageStabilizer.prewarmLicense()
        print("[PixSmartEIS] prewarmLicense ok=\(ok)")
        return ok
    }

    /// 对照片数据做 EIS；失败则返回原始 data。
    static func stabilizePhotoData(_ data: Data, quality: CGFloat = 0.92) -> Data {
        do {
            let stabilized = try PixSmartImageStabilizer.stabilizeImageData(
                data,
                compressionQuality: quality
            )
            return stabilized
        } catch {
            print("[PixSmartEIS] skip: \(error.localizedDescription)")
            return data
        }
    }
}
