import Foundation

/// Presentation-only filtering. Device command recognition and execution stay independent.
enum AIChatRecordFilter {
    // History has no command metadata. Match entire documented commands, never substrings
    // such as “怎么开始拍照” or “How do I take a photo?”. Keep question punctuation.
    private static let executionPhrases: Set<String> = [
        "开始拍照", "拍照", "开始录像", "停止录像", "结束录像",
        "播放音乐", "停止播放", "停止播放音乐", "停止播放（音乐）", "暂停音乐",
        "播放下一曲", "下一曲", "下一首", "播放上一曲", "上一曲", "上一首",
        "调高音量", "声音大一点", "音量大一点", "调低音量", "声音小一点", "音量小一点",
        "接听电话", "拒接电话", "挂断电话",
        "take a photo", "take a picture", "start recording", "stop recording",
        "play music", "stop playing music", "pause music",
        "play the next track", "next track", "next song",
        "play the previous track", "previous track", "previous song",
        "turn up the volume", "louder", "turn down the volume", "quieter",
        "answer the call", "reject the call", "hang up"
    ]

    static func isExecutionCommand(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".。!！"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        return executionPhrases.contains(value)
    }
}
