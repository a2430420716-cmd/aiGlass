"""Build playback/phone-stop contract targets from production controller methods."""
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
state = Path(sys.argv[2]).read_text(encoding="utf-8")


def block(text, marker):
    start = text.index(marker)
    cursor = text.index("{", start) + 1
    depth = 1
    while depth:
        if text[cursor] == "{":
            depth += 1
        elif text[cursor] == "}":
            depth -= 1
        cursor += 1
    return text[start:cursor]


methods = [block(source, marker) for marker in [
    "    func toggleGlassesSound()",
    "    func onGlassesPlaybackStateChanged(",
    "    func onSpeech(",
    "    private func playSpeechOnGlasses(",
]]
legacy = "speechReplayBuffer" in source
output = "import Foundation\n"
if legacy:
    output += block(state, "struct TranslationSpeechReplayBuffer {") + "\n"
output += """
@MainActor final class SimultaneousPlaybackProbe {
    var glassesSoundEnabled = SimultaneousTranslationRecordStore.glassesSoundEnabled
    var translationManager: RealtimeTranslationManager? = RealtimeTranslationManager()
    var isActive = true
    var isRecording = false
    var socketStatus = ""
    var alertMessage: String?
    var speechChunksReceived = 0
"""
if legacy:
    output += "    private var speechReplayBuffer = TranslationSpeechReplayBuffer()\n"
    output += "    init() { speechReplayBuffer.begin() }\n"
output += "\n".join(methods) + "\n}\n"
conversation = (Path(__file__).resolve().parent.parent /
                "AIGlass/ConversationTranslationController.swift").read_text(encoding="utf-8")
output += block(conversation, "struct ConversationTranslationMessage:") + "\n"
output += """
@MainActor final class ConversationPlaybackProbe {
    var manager: RealtimeTranslationManager? = RealtimeTranslationManager()
    var isActive = true
    var glassesRecording = false
    var glassesConnecting = false
    var phoneRecording = false
    var waitingPhoneSocketReady = false
    var awaitingFinalTranslation = false
    var glassesActive: Bool { glassesRecording || glassesConnecting }
    var phoneActive: Bool { phoneRecording || waitingPhoneSocketReady }
    var phoneAutoStopTask: Task<Void, Never>?
    var statusText = ""
    var alertMessage: String?
    var microphoneStops = 0
    func cancelSocketReadyTimeout() {}
    func stopPhoneAudio() { microphoneStops += 1 }
    func enterProcessingStatus(reason: String) { statusText = "processing" }
    func settleProcessingStatus(reason: String) { statusText = "settled" }
    func stopPhone() { stopPhoneRecording() }
"""
output += "\n".join(block(conversation, marker) for marker in [
    "    func replay(",
    "    private func stopPhoneRecording()",
    "    func onFinished(",
    "    func onGlassesPlaybackStateChanged(",
]) + "\n}\n"
Path(sys.argv[3]).write_text(output, encoding="utf-8")
