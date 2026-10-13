import Foundation

@main
enum DisconnectDiagnosticsTests {
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        assertions += 1
    }

    static func main() {
        for oldReady in [false, true] {
            for historicalFlag in [false, true] {
                for audio in [false, true] {
                    var evidence = DisconnectDiagnosticAssessment.Evidence(
                        appReady: oldReady,
                        historicalSystemConnected: historicalFlag,
                        bluetoothAudioPresent: audio
                    )
                    check(DisconnectDiagnosticAssessment.assess(evidence) == .systemBLENotObserved,
                          "Old App READY, historical peer flags and audio do not prove current system BLE presence")
                    evidence.targetRetrieved = true
                    check(DisconnectDiagnosticAssessment.assess(evidence) == .systemBLEPresentAppSessionDisconnected,
                          "Fresh system BLE presence takes precedence over stale app state after didDisconnect")
                    evidence.systemQueryPerformed = false
                    check(DisconnectDiagnosticAssessment.assess(evidence) == .queryUnavailable,
                          "A cached query match is not fresh evidence when query was not executed")
                }
            }
        }

        var evidence = DisconnectDiagnosticAssessment.Evidence(
            isFollowUp: true, appReady: true, readyObservedAfterDisconnect: false
        )
        check(DisconnectDiagnosticAssessment.assess(evidence) == .systemBLENotObserved,
              "A leftover READY at follow-up is not a newly observed recovery")
        evidence.readyObservedAfterDisconnect = true
        check(DisconnectDiagnosticAssessment.assess(evidence) == .appGATTRecovered,
              "A subsequent ready observation for the same target confirms recovery")
        evidence.targetRetrieved = true
        evidence.sessionChanged = true
        check(DisconnectDiagnosticAssessment.assess(evidence) == .appGATTRecovered,
              "The new session's actual READY is reported as recovery, not attributed to the old disconnect")
        evidence.appReady = false
        check(DisconnectDiagnosticAssessment.assess(evidence) == .superseded,
              "A delayed old disconnect assessment cannot label a new session while it is connecting")
        evidence.appReady = true
        evidence.isCurrentContext = false
        check(DisconnectDiagnosticAssessment.assess(evidence) == .superseded,
              "A different target or central invalidates even a READY observation")

        evidence = .init(centralPoweredOn: false, targetRetrieved: true, appReady: true,
                         historicalSystemConnected: true, bluetoothAudioPresent: true)
        check(DisconnectDiagnosticAssessment.assess(evidence) == .queryUnavailable,
              "Bluetooth unavailable cannot be overridden by stale retrieved state or audio")
        evidence = .init(appReady: true, readyObservedAfterDisconnect: true)
        check(DisconnectDiagnosticAssessment.assess(evidence) == .systemBLENotObserved,
              "Immediate callback never classifies pre-cleanup READY as recovery")

        check(DisconnectDiagnosticAssessment.systemBLENotObserved.explanation.contains("不证明"),
              "A negative query explicitly does not prove all physical Bluetooth links disconnected")
        check(DisconnectDiagnosticAssessment.systemBLEPresentAppSessionDisconnected.explanation.contains("连续性"),
              "A positive point-in-time query does not establish physical link continuity")
        print("Disconnect diagnostics: \(assertions) assertions passed")
    }
}
