import Foundation

/// Backend contract shared by userinfo.device[] and get_device_model_list.
enum APIDeviceType: Int, Codable, Sendable {
    case unknown = 0
    case firstGeneration = 1
    case secondGeneration = 2

    nonisolated init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        let number: Int?
        if let integer = try? value.decode(Int.self) {
            number = integer
        } else if let string = try? value.decode(String.self) {
            number = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            number = nil
        }
        self = number.flatMap(Self.init(rawValue:)) ?? .unknown
    }

    var generation: DeviceGeneration {
        switch self {
        case .firstGeneration: .gen1G5K61
        case .secondGeneration: .gen2
        case .unknown: .unknown
        }
    }

    func matches(_ actualGeneration: DeviceGeneration) -> Bool {
        generation != .unknown && generation == actualGeneration
    }
}
