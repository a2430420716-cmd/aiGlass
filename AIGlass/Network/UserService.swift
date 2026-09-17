import Foundation

enum UserService {
    static func sendCode(
        phoneNumber: String,
        type: SMSCodeType,
        token: String? = nil
    ) async throws {
        _ = try await APIClient.post(
            path: "user/send_code",
            body: [
                "phonenum": phoneNumber,
                "type": type.rawValue
            ],
            authorization: token,
            as: EmptyResult.self
        )
    }

    static func changePassword(
        phoneNumber: String,
        code: String,
        password: String,
        type: SMSCodeType,
        token: String? = nil
    ) async throws {
        _ = try await APIClient.post(
            path: "user/change_pwd",
            body: [
                "phonenum": phoneNumber,
                "code": code,
                "type": type.rawValue,
                "password": password
            ],
            authorization: token,
            as: EmptyResult.self
        )
    }

    static func sendPasswordChangeCode(phoneNumber: String, token: String) async throws {
        try await sendCode(
            phoneNumber: phoneNumber,
            type: .changePassword,
            token: token
        )
    }

    static func sendEmailPasswordChangeCode(email: String, token: String) async throws {
        _ = try await APIClient.post(
            path: "user/send_modify_email_code",
            body: ["email": email],
            authorization: token,
            as: EmptyResult.self
        )
    }

    static func changePassword(
        phoneNumber: String,
        code: String,
        password: String,
        token: String
    ) async throws {
        try await changePassword(
            phoneNumber: phoneNumber,
            code: code,
            password: password,
            type: .changePassword,
            token: token
        )
    }

    static func changeEmailPassword(
        email: String,
        code: String,
        password: String,
        token: String
    ) async throws {
        _ = try await APIClient.post(
            path: "user/modify_password",
            body: [
                "email": email,
                "code": code,
                "password": password
            ],
            authorization: token,
            as: EmptyResult.self
        )
    }

    /// 注销账号：POST `user/signout`，对齐 Android `API_ACCOUNT_SIGNOUT`。
    static func signOut(token: String) async throws {
        _ = try await APIClient.post(
            path: "user/signout",
            body: [:],
            authorization: token,
            as: EmptyResult.self
        )
    }

    static func unbindWeChat(token: String) async throws {
        _ = try await APIClient.post(
            path: "user/unbind_wx",
            body: [:],
            authorization: token,
            as: EmptyResult.self
        )
    }

    static func fetchUserInfo(token: String) async throws -> UserInfo {
        let data = try await APIClient.postRaw(
            path: "user/userinfo",
            body: ["client_info": ClientInfo.current],
            authorization: token
        )
        if let raw = String(data: data, encoding: .utf8) {
            print("[userinfo] \(raw)")
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
        guard let apiResponse = try? decoder.decode(APIResponse<UserInfo>.self, from: data),
              let info = apiResponse.result else {
            if let raw = String(data: data, encoding: .utf8) {
                print("[userinfo] decode failed raw=\(raw)")
            }
            throw APIError.decoding
        }
        return info
    }

    static func saveUser(nickname: String, headimg: String, token: String) async throws {
        let payload: [String: Any] = [
            "nickname": nickname,
            "headimg": headimgValueForSave(headimg)
        ]
        print("[save_user] request \(payload)")

        let data = try await APIClient.postRaw(
            path: "user/save_user",
            body: payload,
            authorization: token
        )

        if let raw = String(data: data, encoding: .utf8) {
            print("[save_user] \(raw)")
        }

        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(APIStatus.self, from: data) else {
            throw APIError.decoding
        }
        guard status.code == 0 else {
            throw APIError.server(
                message: status.msg?.isEmpty == false ? status.msg! : L10n.t("保存失败", "Save failed"),
                code: status.code
            )
        }
    }

    static func headimgValueForSave(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var path = trimmed
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            path = url.path
        }

        while path.hasPrefix("/") {
            path = String(path.dropFirst())
        }
        return path
    }

    static func uploadAvatarImage(_ imageData: Data, token: String) async throws -> String {
        let response = try await UploadService.uploadFile(
            fileData: imageData,
            fileName: "avatar.jpg",
            mimeType: "image/jpeg",
            token: token
        )
        return response.path
    }
}
