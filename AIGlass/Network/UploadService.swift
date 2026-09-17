import Foundation

struct UploadFileResponse {
    let id: String
    let path: String
}

enum UploadService {
    static func uploadFile(
        fileData: Data,
        fileName: String,
        mimeType: String,
        token: String,
        category: String = "2"
    ) async throws -> UploadFileResponse {
        let data = try await APIClient.uploadMultipart(
            path: "upload/upload",
            fileData: fileData,
            fileName: fileName,
            mimeType: mimeType,
            queryItems: [URLQueryItem(name: "category", value: category)],
            authorization: token
        )

        if let raw = String(data: data, encoding: .utf8) {
            print("[upload] \(raw)")
        }

        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(APIStatus.self, from: data) else {
            throw APIError.decoding
        }
        guard status.code == 0 else {
            throw APIError.server(
                message: status.msg?.isEmpty == false ? status.msg! : L10n.t("上传失败", "Upload failed"),
                code: status.code
            )
        }

        if let response = try? decoder.decode(APIResponse<UploadFileResult>.self, from: data),
           let result = response.result,
           let id = result.resolvedID,
           let path = result.resolvedPath,
           !id.isEmpty,
           !path.isEmpty {
            return UploadFileResponse(
                id: id,
                path: UserService.headimgValueForSave(path)
            )
        }

        throw APIError.decoding
    }
}

struct UploadFileResult: Decodable {
    let id: FlexibleString?
    let url: String?
    let path: String?
    let file: String?
    let headimg: String?

    var resolvedID: String? {
        id?.value
    }

    var resolvedPath: String? {
        [url, path, file, headimg]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = String(intValue)
        } else {
            value = try container.decode(String.self)
        }
    }
}
