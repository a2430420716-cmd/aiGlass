import Foundation

/// Retain shutdown evidence for one hotspot open, including reports received
/// before the manual-join UI exists. A cached idle status is not closure evidence.
enum Gen1HotspotAvailability: String {
    case awaitingNetwork
    case shuttingDown
    case closed

    var requiresRestart: Bool { self != .awaitingNetwork }

    mutating func receive(command: UInt8, payload: Data) {
        guard command == Gen1Commands.deviceStatusChanged, payload.count == 1 else { return }
        if payload[0] == 4, self != .closed {
            self = .shuttingDown
        } else if payload[0] == 0, self == .shuttingDown {
            self = .closed
        }
        // Later status notifications cannot reopen this hotspot. Only a new
        // explicit open starts another availability record.
    }
}
