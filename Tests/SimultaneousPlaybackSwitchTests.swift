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
    var phoneReplays: [Data] = []
    var glassesReplays: [Data] = []
    var finishRequests: [Bool] = []
    var recordingStops = 0
    var onFinish: (() -> Void)?

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
    func replaySpeechOnPhone(_ data: Data) -> Bool {
        guard canPlay else { return false }
        phoneReplays.append(data)
        return true
    }
    func replaySpeechOnGlasses(_ data: Data) -> Bool {
        guard canPlay else { return false }
        glassesReplays.append(data)
        return true
    }
    func markLocalRecordingStopped(reason: String) { recordingStops += 1 }
    func finish(waitForTranslation: Bool = false) {
        finishRequests.append(waitForTranslation)
        onFinish?()
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

        var textOnly = ConversationTranslationMessage(
            id: UUID(), side: .phone, sourceLanguage: "English", targetLanguage: "中文",
            sourceText: "hello", translatedText: "你好", speechData: nil, hasSpeech: false)
        expect(textOnly.showsPlaybackControl && !textOnly.hasPlayableSpeech,
               "Translated text retains its output control without pretending audio is ready")
        let conversation = ConversationPlaybackProbe()
        let conversationOutput = conversation.manager!
        conversation.replay(textOnly)
        expect(conversation.alertMessage?.contains("not been received") == true,
               "Text-only replay explains the missing audio")
        expect(conversationOutput.glassesReplays.isEmpty, "Text-only results cannot invent speech")
        textOnly.speechData = Data()
        textOnly.hasSpeech = true
        expect(!textOnly.hasPlayableSpeech, "A flag or empty data cannot establish playable speech")
        textOnly.speechData = Data([1])
        expect(!textOnly.hasPlayableSpeech, "Incomplete PCM16 is not playable")
        textOnly.speechData = firstNewSpeech
        expect(textOnly.hasPlayableSpeech, "Audio arriving after text enables replay")
        conversation.alertMessage = nil
        conversation.replay(textOnly)
        expect(conversationOutput.glassesReplays == [firstNewSpeech], "Phone-origin translation replays on glasses")
        let glassesMessage = ConversationTranslationMessage(
            id: UUID(), side: .glasses, sourceLanguage: "中文", targetLanguage: "English",
            sourceText: "你好", translatedText: "hello", speechData: firstNewSpeech, hasSpeech: true)
        conversation.replay(glassesMessage)
        expect(conversationOutput.phoneReplays == [firstNewSpeech], "Glasses-origin translation replays on phone")
        conversationOutput.canPlay = false
        conversation.replay(textOnly)
        expect(conversation.alertMessage?.contains("Settings > Bluetooth") == true &&
               conversation.alertMessage?.contains("Control Center") == true,
               "Glasses output failure gives concrete system audio connection instructions")
        conversation.replay(glassesMessage)
        expect(conversation.alertMessage?.contains("Could not play translation audio") == true,
               "Phone replay failure must not be reported as missing glasses audio")

        let phoneTurn = ConversationPlaybackProbe()
        phoneTurn.phoneRecording = true
        phoneTurn.replay(textOnly)
        expect(phoneTurn.alertMessage?.contains("Stop recording") == true, "Recording blocks replay")
        phoneTurn.stopPhone()
        expect(!phoneTurn.phoneActive && phoneTurn.microphoneStops == 1, "Stop ends microphone capture immediately")
        expect(phoneTurn.awaitingFinalTranslation && phoneTurn.manager?.finishRequests == [true],
               "Phone stop waits for final speech instead of immediately sending stop")
        phoneTurn.alertMessage = nil
        phoneTurn.replay(textOnly)
        expect(phoneTurn.alertMessage?.contains("Waiting for translation audio") == true,
               "Replay cannot interfere with the finishing turn")
        phoneTurn.stopPhone()
        expect(phoneTurn.manager?.finishRequests == [true], "Repeated stop cannot restart finalization")
        phoneTurn.onFinished(waitTimedOut: false)
        expect(!phoneTurn.awaitingFinalTranslation, "Completion releases the next-turn gate")
        phoneTurn.phoneRecording = true
        phoneTurn.stopPhone()
        phoneTurn.onFinished(waitTimedOut: true)
        expect(!phoneTurn.awaitingFinalTranslation && phoneTurn.statusText.contains("timed out"),
               "Bounded timeout releases the gate and reports missing final audio")

        let cancelled = ConversationPlaybackProbe()
        cancelled.waitingPhoneSocketReady = true
        cancelled.stopPhone()
        expect(!cancelled.awaitingFinalTranslation && !cancelled.phoneActive &&
               cancelled.manager?.finishRequests == [false], "Cancelling a pending connection never waits for speech")
        let noManager = ConversationPlaybackProbe()
        noManager.phoneRecording = true
        noManager.manager = nil
        noManager.stopPhone()
        expect(!noManager.awaitingFinalTranslation, "Missing service cannot leave the turn gate stuck")
        let synchronous = ConversationPlaybackProbe()
        synchronous.phoneRecording = true
        synchronous.manager?.onFinish = { [weak synchronous] in synchronous?.onFinished(waitTimedOut: false) }
        synchronous.stopPhone()
        expect(!synchronous.awaitingFinalTranslation && synchronous.statusText == "settled",
               "Immediate finish callback cannot be overwritten by stale processing state")

        var pendingText = textOnly
        pendingText.translatedText = " \n "
        pendingText.speechData = nil
        expect(!pendingText.showsPlaybackControl, "Recognition-only results do not offer a translation replay")
        print("Translation playback and phone completion: \(checks) assertions passed")
    }
}
