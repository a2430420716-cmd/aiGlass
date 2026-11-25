import Foundation

/// Name matching selects a sales model, independently of API/GATT generation.
nonisolated enum PairingDeviceNamePolicy {
    /// Android BleSearchDialog uses the current ScanRecord name before cached names.
    static func discoveredName(advertised: String?, cached: String?) -> String {
        firstNonEmpty([advertised, cached]) ?? ""
    }

    /// Android SelectedDeviceModelManager matches raw model_name, not its display alias.
    static func matchesModel(_ modelName: String?, deviceName: String) -> Bool {
        guard let name = firstNonEmpty([deviceName]) else { return false }
        guard let model = firstNonEmpty([modelName]) else { return true }
        return name.range(of: model, options: .caseInsensitive) != nil
    }

    static func firstNonEmpty(_ candidates: [String?]) -> String? {
        candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
