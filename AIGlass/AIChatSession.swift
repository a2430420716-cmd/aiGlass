import Combine
import Foundation
import UIKit

/// AI 对话消息（可含 BLE 识图回传的 JPEG）。
struct AIChatItem: Identifiable, Equatable {
    enum AIVoiceSource: Equatable {
        case remoteURL(String)
        case localFile(String)
    }

    enum VoiceRecognition: Equatable {
        case recognizing
        case recognized(String)
        case failed(String)
    }

    enum Kind: Equatable {
        case timestamp(String)
        case userText(String)
        case userImage(Data)
        case userRemoteImage(url: String, text: String?)
        case aiRemoteImage(url: String, text: String?)
        case userVideo(url: String, text: String?)
        case aiVideo(url: String, text: String?)
        /// 用户语音气泡：可点播放；下方显示识别中 / 识别文案。
        case userVoice(filePath: String, durationSeconds: Int, recognition: VoiceRecognition)
        /// AI 返回语音气泡：自动播放，也可点击停止或重播；`text` 为同一回复的文案。
        case aiVoice(source: AIVoiceSource, durationSeconds: Int?, text: String?)
        case userLoading(String)
        case aiText(String)
        case error(String)
    }

    let id: UUID
    let kind: Kind
    let date: Date

    init(id: UUID = UUID(), kind: Kind, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.date = date
    }
}

@MainActor
final class AIChatSession: ObservableObject {
    static let shared = AIChatSession()

    @Published private(set) var messages: [AIChatItem] = []
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var canLoadMoreHistory = false

    private var loadingMessageID: UUID?
    private var historyMessageIDs = Set<UUID>()
    private var currentHistoryPage = 0
    private var lastHistoryPage = 1
    private var loadedToken: String?
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "ahh:mm"
        return formatter
    }()

    private init() {}

    /// 对齐 Android AiFragment：首次进入及每次重新进入 AI Tab 都刷新第 1 页。
    func refreshHistoryOnEnter(token: String?) async {
        guard let token, !token.isEmpty else { return }
        if loadedToken != token {
            messages.removeAll()
            historyMessageIDs.removeAll()
            loadingMessageID = nil
            currentHistoryPage = 0
            lastHistoryPage = 1
        }
        loadedToken = token
        await loadHistoryPage(1, token: token, refresh: true)
    }

    func loadMoreHistory(token: String?) async {
        guard let token, !token.isEmpty,
              !isLoadingHistory,
              currentHistoryPage > 0,
              currentHistoryPage < lastHistoryPage else { return }
        await loadHistoryPage(currentHistoryPage + 1, token: token, refresh: false)
    }

    /// 开始识图：插时间戳 + loading。
    func beginImageRecognitionCapture() {
        appendTimestampIfNeeded()
        removeLoadingIfNeeded()
        let loading = AIChatItem(kind: .userLoading(L10n.t("正在识图，等待眼镜回传图片…", "Recognizing image, waiting for glasses…")))
        loadingMessageID = loading.id
        messages.append(loading)
    }

    func updateLoadingProgress(received: Int, total: Int) {
        guard let id = loadingMessageID,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let text: String
        if total > 0 {
            let percent = min(100, max(0, Int((Double(received) / Double(total) * 100).rounded())))
            text = L10n.t("正在接收图片 \(percent)%…", "Receiving image \(percent)%…")
        } else {
            text = L10n.t("正在识图，等待眼镜回传图片…", "Recognizing image, waiting for glasses…")
        }
        messages[index] = AIChatItem(id: id, kind: .userLoading(text), date: messages[index].date)
    }

    func completeImageRecognition(jpeg: Data, token: String?) {
        replaceLoading(with: .userImage(jpeg))
        let pending = AIChatItem(kind: .aiText(L10n.t("识别中…", "Recognizing…")))
        messages.append(pending)
        Task { await requestImageChat(jpeg: jpeg, token: token, pendingID: pending.id) }
    }

    private func requestImageChat(jpeg: Data, token: String?, pendingID: UUID) async {
        guard let token, !token.isEmpty else {
            print("[image_chat] missing token")
            replaceAIMessage(id: pendingID, with: .error(L10n.t("未登录，无法识别", "Not signed in, cannot recognize")))
            return
        }
        do {
            let result = try await ArkChatService.imageChat(jpeg: jpeg, token: token)
            AIVoiceChatManager.shared.playSpeechResponse(result)
            let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if AIChatRecordFilter.isExecutionCommand(text) {
                messages.removeAll { $0.id == pendingID }
            } else if text.isEmpty {
                replaceAIMessage(id: pendingID, with: .error(L10n.t("识别结果为空", "Empty recognition result")))
            } else {
                replaceAIMessage(id: pendingID, with: .aiText(text))
            }
        } catch {
            print("[image_chat] error \(error)")
            replaceAIMessage(
                id: pendingID,
                with: .error(error.localizedDescription.isEmpty ? L10n.t("识别失败", "Recognition failed") : error.localizedDescription)
            )
        }
    }

    private func replaceAIMessage(id: UUID, with kind: AIChatItem.Kind) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            messages.append(AIChatItem(kind: kind))
            return
        }
        messages[index] = AIChatItem(id: id, kind: kind, date: messages[index].date)
    }

    func failImageRecognition(_ message: String) {
        replaceLoading(with: .error(message))
    }

    /// 发出用户语音气泡，下方先显示「正在识别...」。
    @discardableResult
    func beginUserVoiceMessage(filePath: String, durationSeconds: Int) -> UUID {
        appendTimestampIfNeeded()
        let item = AIChatItem(
            kind: .userVoice(
                filePath: filePath,
                durationSeconds: max(1, durationSeconds),
                recognition: .recognizing
            )
        )
        messages.append(item)
        return item.id
    }

    func updateUserVoiceRecognition(id: UUID, recognition: AIChatItem.VoiceRecognition) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              case .userVoice(let path, let duration, _) = messages[index].kind else { return }
        messages[index] = AIChatItem(
            id: id,
            kind: .userVoice(filePath: path, durationSeconds: duration, recognition: recognition),
            date: messages[index].date
        )
    }

    func appendAIText(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !AIChatRecordFilter.isExecutionCommand(value) else { return }
        appendTimestampIfNeeded()
        messages.append(AIChatItem(kind: .aiText(value)))
    }

    @discardableResult
    func appendAIVoice(
        source: AIChatItem.AIVoiceSource,
        durationSeconds: Int?,
        text: String? = nil
    ) -> UUID {
        appendTimestampIfNeeded()
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = AIChatItem(
            kind: .aiVoice(
                source: source,
                durationSeconds: durationSeconds.map { max(1, $0) },
                text: (value?.isEmpty ?? true) ? nil : value
            )
        )
        messages.append(item)
        return item.id
    }

    func clear() {
        messages.removeAll()
        loadingMessageID = nil
        historyMessageIDs.removeAll()
        currentHistoryPage = 0
        lastHistoryPage = 1
        loadedToken = nil
        canLoadMoreHistory = false
    }

    // MARK: - Private

    private func loadHistoryPage(_ page: Int, token: String, refresh: Bool) async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let result = try await ArkChatService.visitLog(page: page, token: token)
            guard loadedToken == token else { return }
            currentHistoryPage = max(1, result.currentPage)
            lastHistoryPage = max(currentHistoryPage, result.lastPage)
            canLoadMoreHistory = result.hasMore || currentHistoryPage < lastHistoryPage

            // 接口每页为新→旧；界面按旧→新显示。
            let pageMessages = makeHistoryMessages(from: result.items.reversed())
            if refresh {
                // 请求期间可能开始了新识图；只替换旧历史，保留实时消息/loading。
                let liveMessages = messages.filter { !historyMessageIDs.contains($0.id) }
                historyMessageIDs = Set(pageMessages.map(\.id))
                messages = pageMessages + liveMessages
            } else {
                historyMessageIDs.formUnion(pageMessages.map(\.id))
                messages.insert(contentsOf: pageMessages, at: 0)
            }
            print(
                "[visit_log] applied page=\(currentHistoryPage)/\(lastHistoryPage) "
                    + "items=\(pageMessages.count) more=\(canLoadMoreHistory)"
            )
        } catch {
            print("[visit_log] load failed page=\(page): \(error.localizedDescription)")
        }
    }

    private func makeHistoryMessages<S: Sequence>(from items: S) -> [AIChatItem]
    where S.Element == VisitLogItem {
        var result: [AIChatItem] = []
        var previousDate: Date?
        for item in items {
            // Android 同样忽略 con_type=3（语音）。
            guard item.contentType != 3,
                  let message = makeHistoryMessage(from: item) else { continue }
            if previousDate == nil
                || message.date.timeIntervalSince(previousDate!) > 5 * 60 {
                result.append(
                    AIChatItem(
                        kind: .timestamp(historyTimeFormatter.string(from: message.date)),
                        date: message.date
                    )
                )
            }
            result.append(message)
            previousDate = message.date
        }
        return result
    }

    private func makeHistoryMessage(from item: VisitLogItem) -> AIChatItem? {
        let isUser = item.type == 1
        let text = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let optionalText: String? = text.isEmpty ? nil : text
        let date = parseHistoryDate(item.createTime)
        let kind: AIChatItem.Kind
        switch item.contentType {
        case 2:
            let mediaURL = historyMediaURL(primary: item.url, fallback: text)
            print(
                "[visit_log][image] build isUser=\(isUser) "
                    + "primary=\(item.url.isEmpty ? "<empty>" : item.url) "
                    + "fallback=\(text.prefix(160)) "
                    + "final=\(mediaURL.isEmpty ? "<empty>" : mediaURL)"
            )
            guard !mediaURL.isEmpty else {
                print("[visit_log][image] missing URL, skip item")
                return nil
            }
            let imageText = mediaURL == ArkChatService.normalizeMediaURL(text) ? nil : optionalText
            kind = isUser
                ? .userRemoteImage(url: mediaURL, text: imageText)
                : .aiRemoteImage(url: mediaURL, text: imageText)
        case 4:
            let mediaURL = historyMediaURL(primary: item.url, fallback: text)
            print(
                "[visit_log][video] build isUser=\(isUser) "
                    + "primary=\(item.url.isEmpty ? "<empty>" : item.url) "
                    + "final=\(mediaURL.isEmpty ? "<empty>" : mediaURL)"
            )
            guard !mediaURL.isEmpty else { return nil }
            let videoText = mediaURL == ArkChatService.normalizeMediaURL(text) ? nil : optionalText
            kind = isUser
                ? .userVideo(url: mediaURL, text: videoText)
                : .aiVideo(url: mediaURL, text: videoText)
        default:
            guard !text.isEmpty, !AIChatRecordFilter.isExecutionCommand(text) else { return nil }
            kind = isUser ? .userText(text) : .aiText(text)
        }
        return AIChatItem(kind: kind, date: date)
    }

    private func historyMediaURL(primary: String, fallback: String) -> String {
        if !primary.isEmpty { return primary }
        let value = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        let looksLikeMedia = lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("/")
            || lower.contains(".jpg")
            || lower.contains(".jpeg")
            || lower.contains(".png")
            || lower.contains(".webp")
            || lower.contains(".heic")
            || lower.contains(".mp4")
            || lower.contains(".mov")
        return looksLikeMedia ? ArkChatService.normalizeMediaURL(value) : ""
    }

    private func parseHistoryDate(_ raw: String) -> Date {
        for formatter in historyDateFormatters {
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        if let seconds = TimeInterval(raw) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        return Date()
    }

    private var historyDateFormatters: [DateFormatter] {
        ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter
        }
    }

    private var historyTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    private func appendTimestampIfNeeded() {
        let stamp = timeFormatter.string(from: Date())
        if let last = messages.last, case .timestamp(let value) = last.kind, value == stamp {
            return
        }
        messages.append(AIChatItem(kind: .timestamp(stamp)))
    }

    private func removeLoadingIfNeeded() {
        guard let id = loadingMessageID else { return }
        messages.removeAll { $0.id == id }
        loadingMessageID = nil
    }

    private func replaceLoading(with kind: AIChatItem.Kind) {
        if let id = loadingMessageID,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = AIChatItem(id: id, kind: kind, date: messages[index].date)
            loadingMessageID = nil
        } else {
            messages.append(AIChatItem(kind: kind))
            loadingMessageID = nil
        }
    }
}
