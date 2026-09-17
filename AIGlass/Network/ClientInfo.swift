import Foundation

enum ClientInfo {
    /// 对齐 Android `client_info`：设备唯一标识（Keychain UUID）。
    static var current: String {
        DeviceIdentity.uuid
    }
}
