import Foundation

@main
@MainActor
enum Gen1HotspotAvailabilityTests {
    static func main() {
        var availability = Gen1HotspotAvailability.awaitingNetwork
        availability.receive(command: Gen1Commands.deviceStatusChanged, payload: Data([0]))
        precondition(!availability.requiresRestart, "Idle alone must not mark the hotspot closed")
        availability.receive(command: Gen1Commands.deviceStatusChanged, payload: Data([2]))
        precondition(!availability.requiresRestart, "NETWORK_OPERATING is expected while joining")
        availability.receive(command: Gen1Commands.deviceStatusQuery, payload: Data([4]))
        availability.receive(command: Gen1Commands.closeHotspot, payload: Data([0]))
        availability.receive(command: Gen1Commands.deviceStatusChanged, payload: Data())
        availability.receive(command: Gen1Commands.deviceStatusChanged, payload: Data([4, 0]))
        precondition(!availability.requiresRestart, "Only a valid one-byte status notification counts")

        // Replay the report: shutdown occurred before the join wait completed
        // and before the manual-join card subscribed to the session's history.
        availability.receive(command: Gen1Commands.deviceStatusChanged, payload: Data([4]))
        precondition(availability == .shuttingDown && availability.requiresRestart,
                     "Stop waiting for this AP as soon as the controller shuts down")
        availability.receive(command: Gen1Commands.deviceStatusChanged, payload: Data([0]))
        precondition(availability == .closed && availability.requiresRestart,
                     "Fast shutdown -> idle must remain visible to a late manual-join subscriber")
        availability.receive(command: Gen1Commands.deviceStatusChanged, payload: Data([2]))
        availability.receive(command: Gen1Commands.deviceStatusChanged, payload: Data([4]))
        availability.receive(command: Gen1Commands.deviceStatusChanged, payload: Data([0]))
        precondition(availability == .closed, "Later reports cannot silently reopen the old hotspot")

        var nextOpen = Gen1HotspotAvailability.awaitingNetwork
        precondition(!nextOpen.requiresRestart, "A new explicit open must not inherit the old shutdown")
        nextOpen.receive(command: Gen1Commands.deviceStatusChanged, payload: Data([0]))
        precondition(!nextOpen.requiresRestart)
        precondition(availability.requiresRestart, "Each hotspot open owns its shutdown evidence")
        print("Gen1 hotspot availability tests passed (9 assertions)")
    }
}
