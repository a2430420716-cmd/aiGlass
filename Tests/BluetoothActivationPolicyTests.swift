@main
enum BluetoothActivationPolicyTests {
    private final class Central {}
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        assertions += 1
    }

    static func main() {
        typealias Policy = BluetoothActivationPolicy
        var central: Central?
        var creations = 0
        let makeCentral = { creations += 1; return Central() }
        for _ in 0..<20 {
            _ = Policy.activate(central: &central, authorization: .notDetermined,
                                userInitiated: false, makeCentral: makeCentral)
        }
        check(central == nil && creations == 0,
              "Startup, login and repeated home refreshes never invoke the central initializer")
        check(Policy.activate(central: &central, authorization: .notDetermined,
                              userInitiated: true, makeCentral: makeCentral),
              "Starting pairing or tapping connect activates Bluetooth")
        let firstCentral = central
        check(firstCentral != nil && creations == 1, "The explicit action creates exactly one central")
        for authorization: Policy.Authorization in [.notDetermined, .allowed, .denied] {
            for userInitiated in [false, true] {
                _ = Policy.activate(central: &central, authorization: authorization,
                                    userInitiated: userInitiated, makeCentral: makeCentral)
            }
        }
        check(central === firstCentral && creations == 1,
              "Repeated taps and permission callbacks reuse the existing central")

        var restored: Central?
        check(Policy.activate(central: &restored, authorization: .allowed,
                              userInitiated: false, makeCentral: makeCentral),
              "Previously authorized startup preserves automatic restoration")
        check(restored != nil && creations == 2, "Authorized restoration initializes a central")

        var blocked: Central?
        for authorization: Policy.Authorization in [.denied, .restricted] {
            for userInitiated in [false, true] {
                check(!Policy.activate(central: &blocked, authorization: authorization,
                                       userInitiated: userInitiated, makeCentral: makeCentral),
                      "An unavailable permission cannot activate a new central")
            }
        }
        check(blocked == nil && creations == 2, "Denied and restricted requests never invoke the initializer")
        _ = Policy.activate(central: &blocked, authorization: .allowed,
                            userInitiated: false, makeCentral: makeCentral)
        check(blocked != nil && creations == 3,
              "Permission granted later in Settings allows automatic initialization")
        print("Bluetooth activation: \(assertions) assertions passed")
    }
}
