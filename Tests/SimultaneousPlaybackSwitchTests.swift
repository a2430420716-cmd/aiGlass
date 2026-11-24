import Foundation

// Hardware output is recorded here. The controller methods under test are copied
// verbatim from production by the runner; settings use the real record store.
@MainActor final class RealtimeTranslationManager {
    enum GlassesPlaybackState { case waiting, playing, unavailable }
    var enabled = false
    var canPlay = true
    var routeAvailable = true
    var routeChecks = 0
    var accepted: [Data] = []
    var queued: [Data] = []
    var playing = false

    func setSpeechPlaybackEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { resetSpeechPlaybackForTurn() }
    }
    func resetSpeechPlaybackForTurn() { queued.removeAll(); playing = false }
    func prepareGlassesSpeechOutput() -> Bool { routeChecks += 1; return routeAvailable }
    func playSpeechOnGlasses(_ data: Data, requiresBluetoothOutput: Bool = true) -> Bool {
        precondition(requiresBluetoothOutput, "No fallback to phone speaker")
        guard enabled, canPlay, !data.isEmpty else { return false }
        accepted.append(data)
        queued.append(data)
        playing = true
        return true
    }
}
enum L10n { nonisolated static func t(_ zh: String, _ en: String) -> String { en } }
enum DebugLogStore { static func logTranslation(_ message: String, detail: String) {} }
enum GlassesAudioRouteController {
    struct Snapshot { let detail = "test route" }
    static var connectionDiagnosticSnapshot: Snapshot { Snapshot() }
}

@main struct SimultaneousPlaybackSwitchTests {
    @MainActor static func main() {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            guard value else {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(1)
            }
        }
        let savedPreference = SimultaneousTranslationRecordStore.glassesSoundEnabled
        defer { SimultaneousTranslationRecordStore.glassesSoundEnabled = savedPreference }
        SimultaneousTranslationRecordStore.glassesSoundEnabled = false
        let controller = SimultaneousPlaybackProbe()
        let output = controller.translationManager!
        let mutedSpeech = Data([1, 0])
        let firstNewSpeech = Data([2, 0])
        let secondNewSpeech = Data([3, 0])

        controller.onSpeech(mutedSpeech)
        expect(output.accepted.isEmpty, "Off discards incoming audio")
        controller.toggleGlassesSound()
        expect(controller.glassesSoundEnabled && output.enabled, "On updates both switch and playback gate")
        expect(output.accepted.isEmpty, "Enabling must not replay speech received while muted")
        expect(SimultaneousTranslationRecordStore.glassesSoundEnabled, "On preference persists")
        expect(output.routeChecks == 0, "Preference changes must not depend on a current audio route")
        controller.onSpeech(firstNewSpeech)
        expect(output.accepted == [firstNewSpeech], "On plays only newly arriving speech")

        controller.toggleGlassesSound()
        expect(!controller.glassesSoundEnabled && !output.enabled, "Off updates both switch and gate")
        expect(!output.playing && output.queued.isEmpty, "Off requests immediate stop and queue clearing")
        controller.onSpeech(mutedSpeech)
        expect(output.accepted == [firstNewSpeech], "Late audio after mute cannot play")
        controller.toggleGlassesSound()
        expect(output.accepted == [firstNewSpeech], "Re-enabling cannot repeat previous output")
        controller.onSpeech(secondNewSpeech)
        expect(output.accepted == [firstNewSpeech, secondNewSpeech], "New output resumes after re-enable")

        output.canPlay = false
        controller.onSpeech(secondNewSpeech)
        expect(controller.glassesSoundEnabled && output.enabled, "Playback failure cannot change user preference")
        expect(SimultaneousTranslationRecordStore.glassesSoundEnabled, "Failure cannot persist an unwanted mute")
        expect(controller.alertMessage != nil, "Output failure gives feedback")
        controller.onGlassesPlaybackStateChanged(.unavailable)
        expect(controller.glassesSoundEnabled && output.enabled, "Route failure callback leaves the switch on")
        controller.toggleGlassesSound()
        controller.onGlassesPlaybackStateChanged(.playing)
        expect(!controller.glassesSoundEnabled && !output.enabled, "Stale playback callback cannot unmute")

        controller.isActive = false
        let before = output.accepted
        controller.onSpeech(firstNewSpeech)
        expect(output.accepted == before, "Leaving the screen discards late speech")
        print("Simultaneous playback switch: \(checks) assertions passed")
    }
}
