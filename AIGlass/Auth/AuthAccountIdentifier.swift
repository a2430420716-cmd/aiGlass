import Foundation

/// Keep contact identifiers used by authenticated requests separate from profile display values.
enum AuthAccountIdentifier {
    static func isPhone(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func maskPhoneForDisplay(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPhone(trimmed) else { return value }
        return "\(trimmed.prefix(3))****\(trimmed.suffix(4))"
    }

    static func isEmail(_ value: String) -> Bool {
        let pattern = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    static func resolving(current: String?, profilePhone: String, profileAccount: String = "") -> String? {
        let account = profileAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPhone(account) || isEmail(account) { return account }
        let current = current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let profile = profilePhone.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPhone(profile) || isEmail(profile) { return profile }
        if isEmail(current) { return current }
        guard isPhone(current) else { return nil }
        if profile.isEmpty { return current }

        // A masked profile may confirm a known number, but cannot supply its missing digits.
        let maskedPhonePattern = #"^[0-9]{3}\*{4}[0-9]{4}$"#
        guard profile.range(of: maskedPhonePattern, options: .regularExpression) != nil,
              profile.prefix(3) == current.prefix(3),
              profile.suffix(4) == current.suffix(4) else { return nil }
        return current
    }
}
