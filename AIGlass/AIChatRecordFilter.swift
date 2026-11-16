import Foundation

/// Presentation-only filtering. Device command recognition and execution stay independent.
enum AIChatRecordFilter {
    // History has no command metadata. Match entire documented commands, never substrings
    // such as “怎么开始拍照” or “How do I take a photo?”. Keep question punctuation.
    private static let executionPhrases: Set<String> = [
        "开始拍照", "拍照", "开始录像", "停止录像", "结束录像",
        "播放音乐", "停止播放", "停止播放音乐", "停止播放（音乐）", "暂停音乐",
        "播放下一曲", "播放下一首", "下一曲", "下一首", "播放上一曲", "播放上一首", "上一曲", "上一首",
        "调高音量", "声音大一点", "音量大一点", "声音音量大一点",
        "调低音量", "声音小一点", "音量小一点", "声音音量小一点",
        "接听电话", "拒接电话", "挂断电话",
        "take a photo", "take a picture", "take a video", "start recording", "stop recording",
        "play music", "stop playing", "stop playing music", "pause music",
        "play next song", "play next track", "play the next song", "play the next track", "next track", "next song",
        "play previous song", "play previous track", "play the previous song", "play the previous track", "previous track", "previous song",
        "volume up", "turn up the volume", "louder", "volume down", "turn down the volume", "quieter",
        "answer the phone", "answer the call", "reject the phone", "reject the call", "hung up", "hang up"
    ]

    // A wake phrase may stand alone or precede one complete device command.
    // Preserve questions and normal conversation addressed to MOCO.
    private static let wakePrefixPattern = #"^(?:[嗨嘿][\s,，、]*眸刻|(?:hi|hey)[\s,，、]+moco)(?=$|[\s,，、:：.!。！]|\p{Han})"#

    static func isExecutionCommand(_ text: String) -> Bool {
        let value = normalized(text)
        if executionPhrases.contains(value) { return true }
        guard let wakeRange = value.range(of: wakePrefixPattern, options: .regularExpression) else { return false }
        let remainder = normalized(String(value[wakeRange.upperBound...]).trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，、:："))
        ))
        return remainder.isEmpty || executionPhrases.contains(remainder)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".。!！,，、")))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
