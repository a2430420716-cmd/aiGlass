import Foundation

@main
enum AIChatRecordFilterTests {
    static func main() {
        let commands = [
            "开始拍照", "拍照", "开始拍照。", "开始录像", "停止录像",
            "播放音乐", "停止播放（音乐）", "下一首", "播放上一曲",
            "调高音量", "声音小一点", "接听电话", "拒接电话", "挂断电话",
            "  Take a photo!\n", "TAKE A PICTURE", "Start   recording.",
            "Stop playing music", "Play the next track", "Turn down the volume", "Hang up",
            // Every independently spoken alternative from the supplied CN/EN table.
            "嗨，眸刻", "嘿，眸刻", "嗨眸刻", "嘿, 眸刻。", "Hi Moco", "HEY MOCO!",
            "播放下一曲", "播放下一首", "下一曲", "播放上一首", "上一曲", "上一首",
            "停止播放", "停止播放音乐", "音量大一点", "声音大一点", "音量小一点",
            "调低音量", "声音音量大一点", "声音音量小一点",
            "Take a video", "Stop playing", "play next song", "play next track",
            "Play previous song", "Play previous track", "Play the previous song", "Play the next song",
            "Volume up", "Volume down", "Answer the phone", "Hung up", "Reject the phone",
            "嗨，眸刻，开始拍照！", "嘿眸刻开始录像", "Hi Moco, take a video.",
            "Hey Moco: volume up!", "Hey   Moco, Play   next song.", "嗨， 眸刻：挂断电话。"
        ]
        for command in commands {
            precondition(AIChatRecordFilter.isExecutionCommand(command), "Command leaked into records: \(command)")
        }

        let conversation = [
            "", "你好", "怎么开始拍照", "开始拍照是什么意思？", "开始拍照？",
            "请解释播放音乐这个指令", "今天拍照的效果很好", "开始拍照后没有声音",
            "How do I take a photo?", "Take a photo?", "I said take a photo yesterday.",
            "Start recording a podcast on iOS", "I prefer louder music", "https://example.com/开始拍照.jpg",
            "播放下一首是什么意思", "教我调低音量", "我说了挂断电话但是没反应",
            "Take a video?", "What does volume up mean?", "Why did you reject the phone?",
            "Hi Moco?", "嗨，眸刻？", "Hi Moco, what is the weather?", "嘿，眸刻，今天星期几",
            "Hi Moco, take a photo?", "嗨，眸刻，开始拍照是什么意思？", "Hi Mocoland", "Hi Moco music history"
        ]
        for text in conversation {
            precondition(!AIChatRecordFilter.isExecutionCommand(text), "Ordinary chat was hidden: \(text)")
        }

        // Commands interleaved with real conversation must not remove surrounding replies.
        let history = ["你好", "开始拍照", "开始拍照", "怎么开始拍照", "播放音乐", "Hi Moco", "Take a video", "今天晴天"]
        let visible = history.filter { !AIChatRecordFilter.isExecutionCommand($0) }
        precondition(visible == ["你好", "怎么开始拍照", "今天晴天"])
        print("AIChatRecordFilterTests: \(commands.count + conversation.count + 1) assertions passed")
    }
}
