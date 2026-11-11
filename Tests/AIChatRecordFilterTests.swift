import Foundation

@main
enum AIChatRecordFilterTests {
    static func main() {
        let commands = [
            "开始拍照", "开始拍照", "开始拍照。", "开始录像", "停止录像",
            "播放音乐", "停止播放（音乐）", "下一首", "播放上一曲",
            "调高音量", "声音小一点", "接听电话", "拒接电话", "挂断电话",
            "  Take a photo!\n", "TAKE A PICTURE", "Start   recording.",
            "Stop playing music", "Play the next track", "Turn down the volume", "Hang up"
        ]
        for command in commands {
            precondition(AIChatRecordFilter.isExecutionCommand(command), "Command leaked into records: \(command)")
        }

        let conversation = [
            "", "你好", "怎么开始拍照", "开始拍照是什么意思？", "开始拍照？",
            "请解释播放音乐这个指令", "今天拍照的效果很好", "开始拍照后没有声音",
            "How do I take a photo?", "Take a photo?", "I said take a photo yesterday.",
            "Start recording a podcast on iOS", "I prefer louder music", "https://example.com/开始拍照.jpg"
        ]
        for text in conversation {
            precondition(!AIChatRecordFilter.isExecutionCommand(text), "Ordinary chat was hidden: \(text)")
        }

        // Commands interleaved with real conversation must not remove surrounding replies.
        let history = ["你好", "开始拍照", "开始拍照", "怎么开始拍照", "播放音乐", "今天晴天"]
        let visible = history.filter { !AIChatRecordFilter.isExecutionCommand($0) }
        precondition(visible == ["你好", "怎么开始拍照", "今天晴天"])
        print("AIChatRecordFilterTests: \(commands.count + conversation.count + 1) assertions passed")
    }
}
