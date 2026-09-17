import Foundation

enum BatteryIcon {
    /// - 100% → Battery6 / Battery_charg6
    /// - 未满电：
    ///   - Battery0：0% ~ 15%（低电量红色）
    ///   - Battery1：16% ~ 40%
    ///   - Battery2：41% ~ 60%
    ///   - Battery3：61% ~ 80%
    ///   - Battery4：81% ~ 90%
    ///   - Battery5：91% ~ 99%
    /// 充电中使用 `Battery_charg*`，否则使用 `Battery*`。
    static func assetName(for percent: Int, isCharging: Bool = false) -> String {
        let value = max(0, min(100, percent))
        let level: Int
        if value >= 100 {
            level = 6
        } else if value <= 15 {
            level = 0
        } else if value <= 40 {
            level = 1
        } else if value <= 60 {
            level = 2
        } else if value <= 80 {
            level = 3
        } else if value <= 90 {
            level = 4
        } else {
            level = 5
        }
        return isCharging ? "Battery_charg\(level)" : "Battery\(level)"
    }
}
