import Foundation

/// 按用户、按眼镜隔离的媒体设置，对齐 Android DeviceMediaSettingsManager。
enum DeviceMediaSettings {
    private static let autoSavePrefix = "device_auto_save"
    private static let recordDurationPrefix = "device_video_record_duration"
    private static let videoResolutionPrefix = "device_video_resolution"
    private static let wearDetectionPrefix = "device_wear_detection"

    static let defaultRecordDurationSeconds = 60
    static let defaultVideoResolution: UInt8 = 2

    static func isAutoSaveEnabled(userId: String?, deviceKey: String?) -> Bool {
        guard let key = storageKey(userId: userId, deviceKey: deviceKey) else {
            return false
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setAutoSaveEnabled(
        _ enabled: Bool,
        userId: String?,
        deviceKey: String?
    ) {
        guard let key = storageKey(userId: userId, deviceKey: deviceKey) else {
            return
        }
        UserDefaults.standard.set(enabled, forKey: key)
    }

    static func recordDurationSeconds(userId: String?, deviceKey: String?) -> Int {
        guard let key = storageKey(prefix: recordDurationPrefix, userId: userId, deviceKey: deviceKey),
              UserDefaults.standard.object(forKey: key) != nil else {
            return defaultRecordDurationSeconds
        }
        return max(1, UserDefaults.standard.integer(forKey: key))
    }

    static func setRecordDurationSeconds(_ seconds: Int, userId: String?, deviceKey: String?) {
        guard let key = storageKey(prefix: recordDurationPrefix, userId: userId, deviceKey: deviceKey) else {
            return
        }
        UserDefaults.standard.set(max(1, seconds), forKey: key)
    }

    static func videoResolution(userId: String?, deviceKey: String?) -> UInt8 {
        guard let key = storageKey(prefix: videoResolutionPrefix, userId: userId, deviceKey: deviceKey),
              UserDefaults.standard.object(forKey: key) != nil else {
            return defaultVideoResolution
        }
        return UInt8(clamping: min(2, max(0, UserDefaults.standard.integer(forKey: key))))
    }

    static func setVideoResolution(_ profile: UInt8, userId: String?, deviceKey: String?) {
        guard let key = storageKey(prefix: videoResolutionPrefix, userId: userId, deviceKey: deviceKey) else {
            return
        }
        UserDefaults.standard.set(Int(min(profile, 2)), forKey: key)
    }

    static func isWearDetectionEnabled(userId: String?, deviceKey: String?) -> Bool {
        guard let key = storageKey(prefix: wearDetectionPrefix, userId: userId, deviceKey: deviceKey) else {
            return false
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setWearDetectionEnabled(_ enabled: Bool, userId: String?, deviceKey: String?) {
        guard let key = storageKey(prefix: wearDetectionPrefix, userId: userId, deviceKey: deviceKey) else {
            return
        }
        UserDefaults.standard.set(enabled, forKey: key)
    }

    private static func storageKey(userId: String?, deviceKey: String?) -> String? {
        storageKey(prefix: autoSavePrefix, userId: userId, deviceKey: deviceKey)
    }

    private static func storageKey(prefix: String, userId: String?, deviceKey: String?) -> String? {
        guard let device = normalized(deviceKey), !device.isEmpty else { return nil }
        let user = normalized(userId) ?? "anonymous"
        return "\(prefix).\(user).\(device)"
    }

    private static func normalized(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(
            value.lowercased().unicodeScalars.map {
                allowed.contains($0) ? Character($0) : "_"
            }
        )
    }
}
