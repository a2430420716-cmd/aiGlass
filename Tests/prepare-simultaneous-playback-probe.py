"""Build a native contract target from the actual production callback methods."""
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
Path(sys.argv[3]).write_text(output, encoding="utf-8")
