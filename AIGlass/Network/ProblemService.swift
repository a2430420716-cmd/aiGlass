import Foundation

struct ProblemItem: Decodable, Identifiable, Equatable {
    let id: Int
    let title: String
    let content: String
    let isEn: Int

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case content
        case isEn = "is_en"
    }
}

struct ProblemClassItem: Decodable, Identifiable, Equatable {
    let id: Int
    let className: String
    let enClassName: String

    enum CodingKeys: String, CodingKey {
        case id
        case className = "class_name"
        case enClassName = "en_class_name"
    }
}

private struct ProblemListPage: Decodable {
    let data: [ProblemItem]
}

enum ProblemService {
    static func fetchProblemList(token: String) async throws -> [ProblemItem] {
        let data = try await APIClient.postRaw(
            path: "problem/get_problem_list",
            body: [:],
            authorization: token
        )

        if let raw = String(data: data, encoding: .utf8) {
            print("[get_problem_list] \(raw)")
        } else {
            print("[get_problem_list] <non-utf8 response>")
        }

        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(APIStatus.self, from: data) else {
            throw APIError.decoding
        }
        guard status.code == 0 else {
            throw APIError.server(
                message: status.msg?.isEmpty == false ? status.msg! : L10n.t("请求失败", "Request failed"),
                code: status.code
            )
        }

        guard let response = try? decoder.decode(APIResponse<ProblemListPage>.self, from: data),
              let page = response.result else {
            throw APIError.decoding
        }
        return page.data
    }

    static func fetchProblemClass(token: String) async throws -> [ProblemClassItem] {
        let data = try await APIClient.postRaw(
            path: "problem/get_problem_class",
            body: [:],
            authorization: token
        )

        if let raw = String(data: data, encoding: .utf8) {
            print("[get_problem_class] \(raw)")
        } else {
            print("[get_problem_class] <non-utf8 response>")
        }

        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(APIStatus.self, from: data) else {
            throw APIError.decoding
        }
        guard status.code == 0 else {
            throw APIError.server(
                message: status.msg?.isEmpty == false ? status.msg! : L10n.t("请求失败", "Request failed"),
                code: status.code
            )
        }

        guard let response = try? decoder.decode(APIResponse<[ProblemClassItem]>.self, from: data),
              let items = response.result else {
            throw APIError.decoding
        }
        return items
    }

    static func submitProblem(
        classID: Int,
        content: String,
        information: String,
        files: [String],
        token: String
    ) async throws {
        let body: [String: Any] = [
            "class_id": classID,
            "content": content,
            "information": information,
            "files": files
        ]

        let data = try await APIClient.postRaw(
            path: "problem/sub_problem",
            body: body,
            authorization: token
        )

        if let raw = String(data: data, encoding: .utf8) {
            print("[sub_problem] \(raw)")
        } else {
            print("[sub_problem] <non-utf8 response>")
        }

        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(APIStatus.self, from: data) else {
            throw APIError.decoding
        }
        guard status.code == 0 else {
            throw APIError.server(
                message: status.msg?.isEmpty == false ? status.msg! : L10n.t("提交失败", "Submit failed"),
                code: status.code
            )
        }
    }
}
