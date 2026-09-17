import Foundation
import Security

/// App 级设备唯一标识：首次启动生成 UUID，持久化到 Keychain（重装/清数据后尽可能保留）。
enum DeviceIdentity {
    private static let service = Bundle.main.bundleIdentifier ?? "com.cyt.aiglass"
    private static let account = "device_uuid"

    private static var cached: String?

    /// 设备唯一标识。
    static var uuid: String {
        if let cached, !cached.isEmpty {
            return cached
        }
        if let existing = readFromKeychain(), !existing.isEmpty {
            cached = existing
            return existing
        }
        let generated = UUID().uuidString
        storeToKeychain(generated)
        cached = generated
        print("[DeviceIdentity] generated uuid=\(generated)")
        return generated
    }

    /// 启动时调用，确保 Keychain 已有 UUID。
    static func bootstrap() {
        let value = uuid
        print("[DeviceIdentity] ready uuid=\(value)")
    }

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            if status != errSecItemNotFound {
                print("[DeviceIdentity] keychain read status=\(status)")
            }
            return nil
        }
        return value
    }

    private static func storeToKeychain(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            print("[DeviceIdentity] keychain store status=\(status)")
        }
    }
}
