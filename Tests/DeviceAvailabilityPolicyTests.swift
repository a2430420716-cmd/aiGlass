import Foundation

@main
enum DeviceAvailabilityPolicyTests {
    private static var assertions = 0
    private static let currentID = "0CDEAF69-D394-EB62-362E-321CB97750B0"
    private static let otherID = "BD65E387-836B-48D3-87B1-0281DF5F5555"
    private static let currentSN = "G5T712604R00313"

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(value(), message)
    }

    private static func matches(_ serial: String?, _ sn: String? = nil,
                                liveID: String? = currentID, liveSN: String? = currentSN) -> Bool {
        DeviceAvailabilityPolicy.matches(serialNumber: serial, hardwareSN: sn,
                                         currentPeripheralID: liveID, currentHardwareSN: liveSN)
    }

    static func main() {
        for ready in [false, true] {
            for card in [false, true] {
                check(DeviceAvailabilityPolicy.canOperate(isBluetoothReady: ready, hasCorrespondingCard: card)
                      == (ready && card), "Both ready transport and a corresponding real card are required")
            }
        }
        check(matches(currentID), "A live UUID can match before the SN arrives")
        check(matches(currentID, liveSN: nil), "Pairing identity queries need not delay a bound UUID")
        check(matches(" \(currentID.lowercased())\n"), "UUID normalization ignores case and outer whitespace")
        check(matches(otherID, currentSN), "Live hardware identity can match a card with an older platform identifier")
        check(matches(nil, " \(currentSN.lowercased())\n"), "Hardware SN matching supports a real SN-only card")
        check(matches(currentSN), "Legacy serial_number containing the actual hardware SN remains supported")
        check(!matches(otherID, "OTHER-SN"), "A single unrelated card cannot authorize the current device")
        check(!matches(otherID, liveSN: nil), "Missing SN cannot turn another UUID into a match")
        check(!matches("Astra A1", "Astra A1"), "Matching product names do not identify the current device")
        check(!matches(nil, nil), "Find-device placeholders and empty identities are not devices")
        check(!matches("  ", "\n"), "Whitespace-only card fields cannot match")
        check(!matches(currentID, currentSN, liveID: nil), "A saved SN cannot substitute for an attached peripheral")
        check(!matches(currentID, currentSN, liveID: " "), "Empty current peripheral identity denies access")
        check(!matches(otherID, nil, liveSN: " "), "Empty live SN never matches absent card SN")

        // Reproduce the report: BLE becomes ready after unbinding, but no real card returns.
        let bleReady = true
        var serials = [currentID]
        func available() -> Bool {
            DeviceAvailabilityPolicy.canOperate(isBluetoothReady: bleReady,
                hasCorrespondingCard: serials.contains { matches($0, liveSN: nil) })
        }
        check(available(), "Bound current device starts available")
        serials.removeAll()
        check(!available(), "Removing the last card revokes availability even while BLE stays ready")
        serials = [otherID]
        check(!available(), "A different account's single device cannot authorize a retained BLE link")
        serials = [otherID, currentID]
        check(available(), "The corresponding real card may occur anywhere in the list")
        serials = [otherID]
        check(!available(), "Replacing a card without changing list count must revoke availability")
        check(!DeviceAvailabilityPolicy.canOperate(isBluetoothReady: false, hasCorrespondingCard: true),
              "A visible bound card never hides a BLE disconnect")
        print("Device availability: \(assertions) assertions passed")
    }
}
