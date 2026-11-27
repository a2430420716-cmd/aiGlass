import Foundation

struct FactoryResetConfirmation {
    enum Outcome: Equatable { case waiting, succeeded, failed, timedOut }
    let targetID: UUID
    let deadline: TimeInterval
    private var response: Outcome = .waiting

    init(targetID: UUID, deadline: TimeInterval) {
        self.targetID = targetID
        self.deadline = deadline
    }

    mutating func receive(_ result: UInt8, from peripheralID: UUID?, now: TimeInterval) -> Bool {
        guard response == .waiting, peripheralID == targetID, now < deadline else { return false }
        switch result {
        case 1: response = .succeeded
        case 2: break
        default: response = .failed
        }
        return true
    }

    func outcome(now: TimeInterval) -> Outcome {
        response == .waiting && now >= deadline ? .timedOut : response
    }
}


/// Device reset and account unbinding are separate confirmations.
struct DeviceUnpairRecovery: Codable, Equatable {
    let accountID: Int
    let serialNumber: String
    let hardwareSN: String
    var resetConfirmed: Bool
    let forceAllowed: Bool
    var backendOrigin: String = ""

    static func bindingPresence(in result: [String: Any], accountID: Int,
                                serialNumber: String, hardwareSN: String) -> Bool? {
        guard result["id"] as? Int == accountID,
              let devices = result["device"] as? [[String: Any]] else { return nil }
        var unidentifiedRow = false
        for device in devices {
            let serial = (device["serial_number"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let sn = (["sn", "device_sn"].compactMap { device[$0] as? String }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if serial.caseInsensitiveCompare(serialNumber) == .orderedSame { return true }
            if !hardwareSN.isEmpty, sn.caseInsensitiveCompare(hardwareSN) == .orderedSame { return true }
            if serial.isEmpty { unidentifiedRow = true }
        }
        // Normal userinfo decoding skips malformed rows; that cannot prove removal.
        return unidentifiedRow ? nil : false
    }
}

enum DeviceUnpairRecoveryStore {
    private static let key = "device.unpair.cloudRecovery.v1"
    private static func records(_ defaults: UserDefaults) -> [DeviceUnpairRecovery] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([DeviceUnpairRecovery].self, from: data) else { return [] }
        return list
    }
    static func pending(accountID: Int, serialNumber: String, backendOrigin: String = "",
                        defaults: UserDefaults = .standard) -> DeviceUnpairRecovery? {
        records(defaults).first {
            $0.accountID == accountID && $0.backendOrigin == backendOrigin
                && $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame
        }
    }
    static func blocksReconnect(accountID: Int?, serialNumber: String, backendOrigin: String = "",
                                defaults: UserDefaults = .standard) -> Bool {
        records(defaults).contains {
            (accountID == nil || $0.accountID == accountID) && $0.backendOrigin == backendOrigin
                && $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame
        }
    }
    static func save(_ record: DeviceUnpairRecovery, defaults: UserDefaults = .standard) {
        var list = records(defaults).filter {
            !($0.accountID == record.accountID && $0.backendOrigin == record.backendOrigin
                && $0.serialNumber.caseInsensitiveCompare(record.serialNumber) == .orderedSame)
        }
        list.append(record)
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
    static func remove(accountID: Int, serialNumber: String, backendOrigin: String = "", defaults: UserDefaults = .standard) {
        let list = records(defaults).filter {
            !($0.accountID == accountID && $0.backendOrigin == backendOrigin
                && $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame)
        }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}
