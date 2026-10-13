import Foundation

/// Business operations require both a ready BLE transport and a real matching home card.
/// A saved peripheral, a model name, or the number of cards cannot establish identity.
nonisolated enum DeviceAvailabilityPolicy {
    static func canOperate(isBluetoothReady: Bool, hasCorrespondingCard: Bool) -> Bool {
        isBluetoothReady && hasCorrespondingCard
    }

    static func matches(
        serialNumber: String?,
        hardwareSN: String?,
        currentPeripheralID: String?,
        currentHardwareSN: String?
    ) -> Bool {
        // Only the currently attached peripheral can supply an identity; no saved-ID fallback.
        guard let currentID = normalized(currentPeripheralID) else { return false }
        let serial = normalized(serialNumber)
        if serial == currentID { return true }
        guard let liveSN = normalized(currentHardwareSN) else { return false }
        // Legacy bindings sometimes stored the hardware SN in serial_number.
        return normalized(hardwareSN) == liveSN || serial == liveSN
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.lowercased()
    }
}
