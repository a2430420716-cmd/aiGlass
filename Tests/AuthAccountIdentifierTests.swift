import Foundation

@main
@MainActor
enum AuthAccountIdentifierTests {
    static func main() {
        let phone = "13800138000"
        let mask = "138****8000"
        precondition(AuthAccountIdentifier.resolving(current: mask, profilePhone: mask, profileAccount: phone) == phone,
                     "userinfo.account repairs an older masked cache without requiring another login")
        precondition(AuthAccountIdentifier.resolving(current: nil, profilePhone: mask, profileAccount: " \(phone) ") == phone)
        precondition(AuthAccountIdentifier.resolving(
            current: phone, profilePhone: mask, profileAccount: "user@example.com"
        ) == "user@example.com", "The server account takes precedence over the phone display field")
        precondition(AuthAccountIdentifier.resolving(current: nil, profilePhone: mask, profileAccount: mask) == nil,
                     "A masked account must never be sent as the full verification-code recipient")
        precondition(AuthAccountIdentifier.resolving(current: phone, profilePhone: mask) == phone,
                     "A profile refresh must not disable password change by replacing the login phone with its mask")
        precondition(AuthAccountIdentifier.resolving(current: "  \(phone)\n", profilePhone: " \(mask) ") == phone)

        let suiteName = "AuthAccountIdentifierTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(phone, forKey: "auth.phoneNumber")
        for _ in 0..<3 {
            let resolved = AuthAccountIdentifier.resolving(
                current: defaults.string(forKey: "auth.phoneNumber"), profilePhone: mask
            )
            defaults.set(resolved, forKey: "auth.phoneNumber")
        }
        precondition(defaults.string(forKey: "auth.phoneNumber") == phone,
                     "Repeated profile refreshes must preserve the usable identifier for the next launch")

        precondition(AuthAccountIdentifier.resolving(current: mask, profilePhone: mask) == nil,
                     "An older masked cache cannot recover the full number")
        precondition(AuthAccountIdentifier.resolving(current: nil, profilePhone: mask) == nil,
                     "A third-party login with only a mask must not fabricate a phone number")
        precondition(AuthAccountIdentifier.resolving(current: "13900138000", profilePhone: mask) == nil,
                     "Do not reuse a phone when the profile mask belongs to another number")
        precondition(AuthAccountIdentifier.resolving(current: "13800138001", profilePhone: mask) == nil)
        precondition(AuthAccountIdentifier.resolving(current: phone, profilePhone: "13900139000") == "13900139000",
                     "A complete server account remains authoritative")
        precondition(AuthAccountIdentifier.resolving(current: nil, profilePhone: phone) == phone)
        precondition(AuthAccountIdentifier.resolving(current: phone, profilePhone: "") == phone)
        precondition(AuthAccountIdentifier.resolving(current: "user@example.com", profilePhone: "") == "user@example.com",
                     "Email accounts must remain usable when the profile has no phone")
        precondition(AuthAccountIdentifier.resolving(current: "user@example.com", profilePhone: mask) == "user@example.com")
        precondition(AuthAccountIdentifier.resolving(current: "username", profilePhone: mask) == nil)
        precondition(AuthAccountIdentifier.resolving(current: "", profilePhone: "") == nil)
        precondition(!AuthAccountIdentifier.isPhone(mask))
        precondition(!AuthAccountIdentifier.isPhone("１３８００１３８０００"))
        precondition(!AuthAccountIdentifier.isEmail("user@"))
        print("Auth account identifier regression tests passed")
    }
}
