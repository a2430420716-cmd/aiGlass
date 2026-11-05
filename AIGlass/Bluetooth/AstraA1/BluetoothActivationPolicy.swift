/// Creating a CoreBluetooth central can trigger the initial system permission alert.
enum BluetoothActivationPolicy {
    enum Authorization {
        case notDetermined
        case restricted
        case denied
        case allowed
    }

    /// Invoke the factory only after the permission and user-action checks.
    static func activate<Central>(
        central: inout Central?, authorization: Authorization,
        userInitiated: Bool, makeCentral: () -> Central
    ) -> Bool {
        if central != nil { return true }
        switch authorization {
        case .allowed:
            break
        case .notDetermined:
            guard userInitiated else { return false }
        case .restricted, .denied:
            return false
        }
        central = makeCentral()
        return true
    }
}
