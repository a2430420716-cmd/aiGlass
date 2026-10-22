import Foundation

@main
enum Gen2OtaRecoveryStateTests {
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    static func main() {
        let target = UUID()
        let other = UUID()
        var state = Gen2OtaRecoveryState()

        check(state.targetID == nil && !state.canCancelPreparation,
              "An idle app cannot cancel a device's pre-existing OTA")
        check(!state.acceptPreparation(from: target), "An unsolicited ACK cannot create an OTA session")
        check(!state.markUpgradeSubmitted(to: target), "An unsolicited submission cannot create a session")

        state.begin(targetID: target)
        check(state.targetID == target, "Beginning an OTA captures the selected device")
        check(!state.preparationAccepted && !state.upgradeSubmitted, "New preparation has no device acceptance")
        check(!state.canCancelPreparation, "A busy rejection does not authorize cancelling the active firmware update")
        check(!state.acceptPreparation(from: other), "Another device's ACK must be ignored")
        check(!state.markUpgradeSubmitted(to: other), "Another device's submission must be ignored")
        check(state.targetID == target && !state.preparationAccepted && !state.upgradeSubmitted,
              "Old-device callbacks cannot alter the active session")

        check(state.acceptPreparation(from: target), "Successful hotspot preparation grants cleanup ownership")
        check(state.canCancelPreparation, "An accepted preparation can be cancelled when hotspot setup fails")
        check(state.canCancelPreparation(for: target), "Cleanup may be sent to the original device")
        check(!state.canCancelPreparation(for: other), "Cleanup may never be sent to a different connected device")
        check(state.acceptPreparation(from: target), "A duplicate successful preparation ACK is harmless")
        check(state.markUpgradeSubmitted(to: target), "The selected device may begin upgrading")
        check(state.upgradeSubmitted && !state.canCancelPreparation,
              "Once firmware is submitted, a later BLE disconnect must not trigger cancellation")
        check(!state.acceptPreparation(from: target), "A delayed preparation ACK cannot undo submission")
        check(!state.canCancelPreparation(for: target), "Delayed ACKs cannot reauthorize destructive cleanup")
        check(state.markUpgradeSubmitted(to: target), "Duplicate submission/progress remains terminal for cleanup")
        check(!state.canCancelPreparation, "Repeated submission retains cancellation protection")

        state.finish()
        check(state.targetID == nil && !state.preparationAccepted && !state.upgradeSubmitted,
              "Finishing clears ownership and phase together")
        check(!state.acceptPreparation(from: target), "A late ACK after completion cannot reopen cleanup ownership")
        check(!state.markUpgradeSubmitted(to: target), "Late progress after completion cannot reopen a session")
        check(!state.canCancelPreparation, "No cleanup can outlive its OTA attempt")

        state.begin(targetID: target)
        check(state.acceptPreparation(from: target), "A retry may obtain new preparation ownership")
        state.begin(targetID: other)
        check(state.targetID == other && !state.preparationAccepted && !state.upgradeSubmitted,
              "Switching the OTA target resets all previous acceptance")
        check(!state.acceptPreparation(from: target), "The previous target's delayed ACK is rejected")
        check(!state.markUpgradeSubmitted(to: target), "The previous target's progress is rejected")
        check(!state.canCancelPreparation, "Previous target callbacks cannot authorize new-target cleanup")
        check(state.acceptPreparation(from: other), "Only the replacement target can grant new ownership")
        check(state.canCancelPreparation(for: other) && !state.canCancelPreparation(for: target),
              "New preparation ownership is scoped to exactly one device")

        state.begin(targetID: target)
        check(state.markUpgradeSubmitted(to: target), "Submission is protective even if the preparation ACK was missed")
        check(!state.acceptPreparation(from: target) && !state.canCancelPreparation,
              "A late preparation reply cannot cancel an upgrade already observed in progress")
        state.begin(targetID: target)
        check(!state.preparationAccepted && !state.upgradeSubmitted && !state.canCancelPreparation,
              "A new attempt on the same device starts with no inherited ownership")

        check(!state.markAlgorithmInstallSubmitted(to: other), "Another device cannot start this session's DLL install")
        check(!state.algorithmInstallInFlight, "An unrelated DLL submission cannot alter cancellation state")
        check(state.acceptPreparation(from: target), "The active attempt owns its accepted hotspot preparation")
        check(state.markAlgorithmInstallSubmitted(to: target), "A queued DLL install protects the selected device")
        check(state.algorithmInstallInFlight && !state.canCancelPreparation,
              "DLL install cannot be cancelled while the device may be writing algorithm files")
        check(state.acceptPreparation(from: target) && !state.canCancelPreparation,
              "A delayed preparation ACK cannot remove DLL installation protection")
        check(!state.markAlgorithmInstallFinished(from: other), "An unrelated DLL result cannot remove write protection")
        check(state.algorithmInstallInFlight && !state.canCancelPreparation,
              "Skipping a timed-out DLL step does not imply that the device stopped writing")
        check(state.markAlgorithmInstallFinished(from: target), "An explicit terminal DLL result ends installation")
        check(!state.algorithmInstallInFlight && state.canCancelPreparation,
              "After DLL installation has definitively ended, an owned preparation can be cleaned up")
        check(!state.markAlgorithmInstallFinished(from: target), "A duplicate terminal DLL result is harmless")

        check(state.markAlgorithmInstallSubmitted(to: target), "A second DLL install can become active")
        check(state.markUpgradeSubmitted(to: target), "Firmware submission is independently protected")
        check(state.markAlgorithmInstallFinished(from: target), "DLL completion can arrive after firmware submission")
        check(state.upgradeSubmitted && !state.canCancelPreparation,
              "Completing DLL installation never removes firmware write protection")

        check(state.markAlgorithmInstallSubmitted(to: target), "The old session has an active DLL install")
        state.begin(targetID: other)
        check(!state.algorithmInstallInFlight, "Changing the OTA target clears the old DLL state")
        check(!state.markAlgorithmInstallSubmitted(to: target), "An old target cannot start DLL state in a new session")
        check(state.acceptPreparation(from: other) && state.markAlgorithmInstallSubmitted(to: other),
              "The new target owns its own active preparation and DLL installation")
        check(!state.markAlgorithmInstallFinished(from: target) && state.algorithmInstallInFlight,
              "An old target's completion cannot unlock cancellation during the new target's install")
        state.finish()
        check(!state.algorithmInstallInFlight && !state.canCancelPreparation, "Finishing clears DLL ownership too")
        check(!state.markAlgorithmInstallSubmitted(to: other), "A late DLL submission cannot reopen a finished session")
        check(!state.markAlgorithmInstallFinished(from: other), "A late DLL result cannot reopen a finished session")

        func decision(
            savedID: UUID?, connectedID: UUID?, isReady: Bool,
            isGen2: Bool, elapsed: TimeInterval
        ) -> Gen2OtaRecoveryState.ConnectionDecision {
            Gen2OtaRecoveryState.connectionDecision(
                targetID: target, savedID: savedID, connectedID: connectedID,
                isReady: isReady, isGen2: isGen2, elapsed: elapsed, timeout: 20
            )
        }

        check(decision(savedID: target, connectedID: nil, isReady: false, isGen2: false, elapsed: 0) == .wait,
              "A transient hotspot-induced BLE disconnect allows reconnect")
        check(decision(savedID: target, connectedID: target, isReady: false, isGen2: false, elapsed: 19.999) == .wait,
              "Unknown generation during discovery does not abort reconnect before the deadline")
        check(decision(savedID: target, connectedID: target, isReady: false, isGen2: true, elapsed: 19.999) == .wait,
              "A correct peripheral still needs services and notifications ready")
        check(decision(savedID: target, connectedID: target, isReady: true, isGen2: true, elapsed: 5) == .ready,
              "OTA resumes after the same second-generation device becomes ready")
        check(decision(savedID: target, connectedID: target, isReady: true, isGen2: true, elapsed: 20) == .ready,
              "A ready device wins at the exact deadline")
        check(decision(savedID: target, connectedID: target, isReady: true, isGen2: true, elapsed: 21) == .ready,
              "An already completed reconnect wins over a delayed timer check")
        check(decision(savedID: target, connectedID: nil, isReady: false, isGen2: false, elapsed: 20) == .timedOut,
              "A missing device fails at the exact deadline")
        check(decision(savedID: target, connectedID: target, isReady: false, isGen2: false, elapsed: 20) == .timedOut,
              "Discovery that never finishes also obeys the deadline")
        check(decision(savedID: target, connectedID: target, isReady: false, isGen2: true, elapsed: 21) == .timedOut,
              "Known generation cannot extend the reconnect deadline")
        check(decision(savedID: target, connectedID: nil, isReady: true, isGen2: true, elapsed: 1) == .wait,
              "A stale ready flag without a live peripheral cannot authorize OTA commands")
        check(decision(savedID: target, connectedID: nil, isReady: true, isGen2: true, elapsed: 20) == .timedOut,
              "A stale ready flag cannot prevent timeout")
        check(decision(savedID: target, connectedID: target, isReady: true, isGen2: false, elapsed: 0) == .targetChanged,
              "A ready first-generation device cannot receive second-generation OTA commands")
        check(decision(savedID: target, connectedID: target, isReady: true, isGen2: false, elapsed: 20) == .targetChanged,
              "Incompatible target is diagnosed before timeout")

        for elapsed: TimeInterval in [0, 20, 21] {
            check(decision(savedID: nil, connectedID: target, isReady: true, isGen2: true, elapsed: elapsed) == .targetChanged,
                  "Unbinding immediately invalidates OTA, including a stale ready connection")
            check(decision(savedID: other, connectedID: target, isReady: true, isGen2: true, elapsed: elapsed) == .targetChanged,
                  "Changing the saved target invalidates OTA before any command or timeout")
            check(decision(savedID: target, connectedID: other, isReady: false, isGen2: false, elapsed: elapsed) == .targetChanged,
                  "Discovering a different live peripheral immediately invalidates the old OTA")
            check(decision(savedID: target, connectedID: other, isReady: true, isGen2: true, elapsed: elapsed) == .targetChanged,
                  "A ready replacement peripheral must never receive the old OTA's commands")
        }

        // Missing the final progress notification must not turn a real update
        // into a failure or authorize cancellation of an ongoing write.
        check(Gen2OtaResultDecision.evaluate(targetVersion: "1.2.3", freshVersion: "v1.2.3",
                                            freshIdle: false, receivedCompletion: false) == .completed,
              "A fresh target version proves success even when progress 100 was lost")
        check(Gen2OtaResultDecision.evaluate(targetVersion: "1.2.3", freshVersion: "1.2.2",
                                            freshIdle: false, receivedCompletion: false) == .unconfirmed,
              "Reading the old version while the device is busy cannot prove failure")
        check(Gen2OtaResultDecision.evaluate(targetVersion: "1.2.3", previousVersion: "1.2.2", freshVersion: "1.2.2",
                                            freshIdle: true, receivedCompletion: false) == .failed,
              "After the recovery window, a fresh old version plus fresh idle proves failure")
        for version: String? in [nil, "", "   ", "N/A", "unknown", "--", "error"] {
            check(Gen2OtaResultDecision.evaluate(targetVersion: "1.2.3", freshVersion: version,
                                                freshIdle: true, receivedCompletion: false) == .unconfirmed,
                  "Missing, cached-only or invalid version evidence must never authorize cancellation")
        }
        check(Gen2OtaResultDecision.evaluate(targetVersion: "1.2.3", freshVersion: "1.2.2",
                                            freshIdle: true, receivedCompletion: true) == .completed,
              "Late progress 100 wins over an earlier mismatched version")
        check(FirmwareVersionComparator.versionsMatch("V1.2.3.0\n", target: "1.2.3"),
              "Equivalent numeric formatting does not create a false failed upgrade")
        check(FirmwareVersionComparator.versionsMatch("V02.01.01.08-beta1", target: "2.1.1.8-beta1"),
              "Device beta versions with leading zeroes compare correctly")
        check(Gen2OtaResultDecision.evaluate(targetVersion: "1.2.3", previousVersion: "1.2.1", freshVersion: "1.2.2",
                                            freshIdle: true, receivedCompletion: false) == .unconfirmed,
              "A changed version with an unexpected build is not treated as failed flashing")
        check(Gen2OtaResultDecision.evaluate(targetVersion: "1.2.3", freshVersion: "1.2.2",
                                            freshIdle: true, receivedCompletion: false) == .unconfirmed,
              "Missing the pre-upgrade version cannot prove that the old version remains installed")
        check(!FirmwareVersionComparator.versionsMatch("1.2.3-build1", target: "1.2.3-build2"),
              "Different build identifiers remain distinct")
        check(!FirmwareVersionComparator.versionsMatch("1.2.3.4.5", target: "1.2.3.4.6"),
              "Version comparison cannot silently discard extra segments")

        var deadline = Gen2OtaProgressDeadline(now: 100)
        check(!deadline.hasExpired(now: 279, inactivity: 180), "No premature inactivity timeout")
        deadline.receivedProgress(now: 270)
        check(!deadline.hasExpired(now: 300, inactivity: 180),
              "An upgrade still making progress is not failed at the original 180 second deadline")
        check(deadline.hasExpired(now: 450, inactivity: 180), "Stalled progress obeys its own inactivity deadline")
        deadline.receivedProgress(now: 999)
        check(deadline.hasExpired(now: 1000, inactivity: 180), "A stream of progress cannot extend the hard upper bound")

        state.begin(targetID: target)
        check(!state.confirmFailure(for: target), "No accepted preparation or submission means no cleanup ownership")
        check(state.markUpgradeSubmitted(to: target), "The current attempt submitted the upgrade")
        check(!state.canCancelFailedAttempt(for: target), "Submission plus local timeout alone cannot cancel flashing")
        check(!state.confirmFailure(for: other), "Another device's failure cannot authorize cancellation")
        check(state.confirmFailure(for: target), "Reconciled failure authorizes cleanup of the owned upgrade")
        check(state.canCancelFailedAttempt(for: target) && !state.canCancelFailedAttempt(for: other),
              "Failure cleanup is scoped to the original target")
        state.receiveProgress(from: target, percent: 90)
        check(!state.canCancelFailedAttempt(for: target), "Resumed progress revokes earlier failure cleanup authorization")
        check(state.confirmFailure(for: target), "Only newly confirmed failure can authorize cleanup again")
        state.markUpgradeCompleted(from: other)
        check(state.canCancelFailedAttempt(for: target), "Another device's completion cannot change this attempt")
        state.markUpgradeCompleted(from: target)
        check(!state.canCancelFailedAttempt(for: target) && !state.confirmFailure(for: target),
              "A late success irrevocably revokes pending failure cleanup")
        state.begin(targetID: other)
        check(!state.failureConfirmed && !state.upgradeCompleted && !state.canCancelFailedAttempt(for: other),
              "A retry cannot inherit failure or completion evidence")
        check(state.acceptPreparation(from: other) && state.markAlgorithmInstallSubmitted(to: other),
              "The new attempt owns algorithm installation")
        check(state.confirmFailure(for: other) && state.canCancelFailedAttempt(for: other),
              "A terminal algorithm flow failure has its own explicit cancellation path")
        state.finish()
        check(!state.confirmFailure(for: other) && !state.canCancelFailedAttempt(for: other),
              "No failure cleanup can outlive its attempt")

        print("Gen2 OTA recovery state: \(assertions) assertions passed")
    }
}
