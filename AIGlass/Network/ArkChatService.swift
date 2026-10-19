import Foundation

struct ImageChatResult: Decodable {
    let commandType: Int?
    let speechType: Int?
    let text: String?
    let speech: String?
    /// 用户语音 ASR 文本（若接口有返回）。
    let asr: String?

    enum CodingKeys: String, CodingKey {
        case commandType = "command_type"
        case speechType = "speech_type"
        case text
        case speech
        case asr
        case asrText = "asr_text"
        case query
        case question
        case userText = "user_text"
        case content
        case answer
        case message
        case reply
        case output
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandType = container.decodeFlexibleInt(forKey: .commandType)
        speechType = container.decodeFlexibleInt(forKey: .speechType)
        speech = container.decodeFlexibleString(forKey: .speech)

        // 对齐安卓 AiApiManager.extractAnswer：`text` 缺失时回退到同义字段。
        let answerCandidates = [
            container.decodeFlexibleString(forKey: .text),
            container.decodeFlexibleString(forKey: .content),
            container.decodeFlexibleString(forKey: .answer),
            container.decodeFlexibleString(forKey: .message),
            container.decodeFlexibleString(forKey: .reply),
            container.decodeFlexibleString(forKey: .output)
        ]
        text = answerCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        let asrCandidates = [
            container.decodeFlexibleString(forKey: .asr),
            container.decodeFlexibleString(forKey: .asrText),
            container.decodeFlexibleString(forKey: .query),
            container.decodeFlexibleString(forKey: .question),
            container.decodeFlexibleString(forKey: .userText)
        ]
        asr = asrCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

struct VisitLogPage: Decodable {
    let currentPage: Int
    let lastPage: Int
    let hasMore: Bool
    let items: [VisitLogItem]

    enum CodingKeys: String, CodingKey {
        case currentPage = "current_page"
        case lastPage = "last_page"
        case hasMore = "has_more"
        case items = "data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPage = container.decodeFlexibleInt(forKey: .currentPage, default: 1)
        lastPage = container.decodeFlexibleInt(forKey: .lastPage, default: currentPage)
        hasMore = container.decodeFlexibleBool(
            forKey: .hasMore,
            default: currentPage < lastPage
        )
        items = (try? container.decode([VisitLogItem].self, forKey: .items)) ?? []
    }
}

struct VisitLogItem: Decodable {
    let type: Int
    let contentType: Int
    let content: String
    let url: String
    let createTime: String

    enum CodingKeys: String, CodingKey {
        case type
        case contentType = "con_type"
        case content
        case url
        case fileURL = "file_url"
        case imageURL = "image_url"
        case mediaURL = "media_url"
        case filePath = "file_path"
        case path
        case createTime = "create_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = container.decodeFlexibleInt(forKey: .type)
        contentType = container.decodeFlexibleInt(forKey: .contentType)
        content = container.decodeFlexibleString(forKey: .content)
        let mediaCandidates = [
            ("url", container.decodeFlexibleString(forKey: .url)),
            ("file_url", container.decodeFlexibleString(forKey: .fileURL)),
            ("image_url", container.decodeFlexibleString(forKey: .imageURL)),
            ("media_url", container.decodeFlexibleString(forKey: .mediaURL)),
            ("file_path", container.decodeFlexibleString(forKey: .filePath)),
            ("path", container.decodeFlexibleString(forKey: .path)),
        ]
        let rawURL = mediaCandidates
            .map(\.1)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        url = ArkChatService.normalizeMediaURL(rawURL)
        createTime = container.decodeFlexibleString(forKey: .createTime)

        // 图片/视频：打原始字段 + 归一化后地址，方便抓日志排查加载失败。
        if contentType == 2 || contentType == 4 {
            let nonEmpty = mediaCandidates
                .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { "\($0.0)=\($0.1)" }
                .joined(separator: " | ")
            print(
                "[visit_log][media] type=\(type) con_type=\(contentType) "
                    + "raw=[\(nonEmpty.isEmpty ? "empty" : nonEmpty)] "
                    + "normalized=\(url.isEmpty ? "<empty>" : url) "
                    + "content=\(content.prefix(120))"
            )
        }
    }
}

enum ArkChatService {
    /// 视觉理解：multipart 上传识图 JPEG，返回识别文案。
    static func imageChat(jpeg: Data, token: String) async throws -> ImageChatResult {
        let data = try await APIClient.uploadMultipart(
            path: "arkchat/image_chat",
            fileData: jpeg,
            fileName: "vision.jpg",
            mimeType: "image/jpeg",
            formFields: ["category": "2"],
            authorization: token
        )

        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        print("[image_chat] \(raw)")

        let decoder = JSONDecoder()
        if let response = try? decoder.decode(APIResponse<ImageChatResult>.self, from: data),
           let result = response.result {
            return result
        }

        // 兼容直接返回 result 对象的形态。
        if let result = try? decoder.decode(ImageChatResult.self, from: data),
           let text = result.text, !text.isEmpty {
            return result
        }

        throw APIError.decoding
    }

    /// 眼镜语音提问：上传 AAC/M4A（对齐安卓 application/octet-stream），返回文本与可选 TTS。
    static func voiceChat(
        audio: Data,
        fileName: String,
        token: String
    ) async throws -> ImageChatResult {
        let data = try await APIClient.uploadMultipart(
            path: "arkchat/get_voice_chat",
            fileData: audio,
            fileName: fileName,
            mimeType: "application/octet-stream",
            authorization: token,
            timeout: 120
        )
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        print("[voice_chat] \(raw)")

        let decoder = JSONDecoder()
        if let response = try? decoder.decode(APIResponse<ImageChatResult>.self, from: data),
           let result = response.result {
            return result
        }
        if let result = try? decoder.decode(ImageChatResult.self, from: data) {
            return result
        }
        throw APIError.decoding
    }

    /// AI 对话历史。服务端按页返回新→旧，UI 再反转为旧→新。
    static func visitLog(page: Int, token: String) async throws -> VisitLogPage {
        let data = try await APIClient.getRaw(
            path: "visitLog/getVisitLog",
            queryItems: [
                URLQueryItem(name: "page", value: String(max(1, page)))
            ],
            authorization: token
        )
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        print("[visit_log] \(raw)")

        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(APIResponse<VisitLogPage>.self, from: data),
              let result = response.result else {
            throw APIError.decoding
        }
        return result
    }

    static func normalizeMediaURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("//") {
            value = "https:" + value
        }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return percentEncodedMediaURL(value)
        }
        let root = BackendRouting.rootURL
        let relative = value.hasPrefix("/") ? String(value.dropFirst()) : value
        let absolute = URL(string: relative, relativeTo: root)?.absoluteURL.absoluteString ?? value
        return percentEncodedMediaURL(absolute)
    }

    private static func percentEncodedMediaURL(_ value: String) -> String {
        if URL(string: value) != nil, !value.contains(" ") {
            return value
        }
        return value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? value
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key, default defaultValue: String = "") -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return defaultValue
    }

    func decodeFlexibleInt(forKey key: Key, default defaultValue: Int = 0) -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) {
            return Int(value) ?? defaultValue
        }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        return defaultValue
    }

    func decodeFlexibleBool(forKey key: Key, default defaultValue: Bool) -> Bool {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? decode(String.self, forKey: key) {
            return value == "1" || value.lowercased() == "true"
        }
        return defaultValue
    }
}
