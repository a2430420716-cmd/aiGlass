import Foundation

enum SMSCodeType: String {
    case login = "1"
    case changePassword = "2"
    case forgotPassword = "3"
}

struct LoginResult: Decodable {
    let token: String?
    let accessToken: String?
    let access_token: String?
    let authorization: String?
    let authToken: String?
    let phonenum: String?
    let userId: String?
    let user_id: String?

    enum CodingKeys: String, CodingKey {
        case token
        case accessToken
        case access_token
        case authorization
        case Authorization
        case authToken = "auth_token"
        case phonenum
        case userId
        case user_id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        access_token = try container.decodeIfPresent(String.self, forKey: .access_token)
        authorization = try container.decodeIfPresent(String.self, forKey: .authorization)
            ?? container.decodeIfPresent(String.self, forKey: .Authorization)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
        phonenum = try container.decodeIfPresent(String.self, forKey: .phonenum)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        user_id = try container.decodeIfPresent(String.self, forKey: .user_id)
    }

    var resolvedToken: String? {
        token ?? accessToken ?? access_token ?? authorization ?? authToken
    }

    var resolvedUserID: String? {
        userId ?? user_id
    }
}

/// 微信登录结果：`get_wxuser_info` / `login_by_wx` 通用响应。
/// 已绑定手机号 → `token` 有值；未绑定 → 返回 `openid` + 微信资料，需走绑定页。
struct WeChatLoginResult: Decodable {
    let token: String?
    let openid: String?
    let nickname: String?
    let headimg: String?
    let sex: Int?

    enum CodingKeys: String, CodingKey {
        case token
        case accessToken
        case access_token
        case authorization
        case Authorization
        case openid
        case nickname
        case headimg
        case sex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tokenValue = try container.decodeIfPresent(String.self, forKey: .token)
        let accessTokenValue = try container.decodeIfPresent(String.self, forKey: .accessToken)
        let accessTokenSnake = try container.decodeIfPresent(String.self, forKey: .access_token)
        let authorizationValue = try container.decodeIfPresent(String.self, forKey: .authorization)
        let authorizationCap = try container.decodeIfPresent(String.self, forKey: .Authorization)
        token = tokenValue ?? accessTokenValue ?? accessTokenSnake ?? authorizationValue ?? authorizationCap
        openid = try container.decodeIfPresent(String.self, forKey: .openid)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        headimg = try container.decodeIfPresent(String.self, forKey: .headimg)
        // sex 兼容 Int / String
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: .sex) {
            sex = intValue
        } else if let strValue = try? container.decodeIfPresent(String.self, forKey: .sex) {
            sex = Int(strValue)
        } else {
            sex = nil
        }
    }

    var resolvedToken: String? {
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return token
    }

    var hasToken: Bool { resolvedToken != nil }
}

enum AuthService {
    private static let appleLoginURL = URL(string: "https://glasses.mocoviso.com/api/login/login_by_apple")!

    /// 根据服务端识别的客户端 IP 判断是否中国：中国手机号登录，海外邮箱登录。
    /// 解析失败或请求失败时由调用方 fallback 为手机号模式。
    static func fetchIsChinaIP() async throws -> Bool {
        let data = try await APIClient.postRaw(path: "login/is_china_ip", body: [:])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decoding
        }
        let code = (json["code"] as? Int)
            ?? (json["code"] as? NSNumber)?.intValue
        guard code == 0 else {
            throw APIError.server(
                message: (json["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L10n.t("请求失败", "Request failed"),
                code: code ?? -1
            )
        }
        guard let parsed = parseChinaIPResult(json["result"]) else {
            throw APIError.decoding
        }
        return parsed
    }

    /// 登录/忘记密码获取验证码。type: 1登录 2修改密码 3忘记密码
    static func sendSMS(phoneNumber: String, type: SMSCodeType) async throws {
        _ = try await APIClient.post(
            path: "login/send_sms",
            body: [
                "phonenum": phoneNumber,
                "type": type.rawValue
            ],
            as: EmptyResult.self
        )
    }

    /// 邮箱登录验证码
    static func sendEmailCode(email: String) async throws {
        _ = try await APIClient.post(
            path: "login/send_email_code",
            body: ["email": email],
            as: EmptyResult.self
        )
    }

    /// 手机号验证码登录
    static func login(phoneNumber: String, code: String) async throws -> LoginResult? {
        try await APIClient.post(
            path: "login/dologin",
            body: [
                "phonenum": phoneNumber,
                "code": code
            ],
            as: LoginResult.self
        )
    }

    /// 邮箱验证码登录/注册
    static func loginByEmailCode(email: String, code: String) async throws -> LoginResult? {
        try await APIClient.post(
            path: "login/register_by_email",
            body: [
                "email": email,
                "code": code
            ],
            as: LoginResult.self
        )
    }

    /// 账号密码登录
    static func loginByPassword(phoneNumber: String, password: String) async throws -> LoginResult? {
        try await APIClient.post(
            path: "login/login_by_pwd",
            body: [
                "phonenum": phoneNumber,
                "password": password
            ],
            as: LoginResult.self
        )
    }

    /// 邮箱密码登录
    static func loginByEmailPassword(email: String, password: String) async throws -> LoginResult? {
        try await APIClient.post(
            path: "login/login_by_email",
            body: [
                "email": email,
                "password": password
            ],
            as: LoginResult.self
        )
    }

    /// Apple 授权登录。服务端要求 Apple 返回的 identity token JWT，而非本地 user 标识。
    static func loginByApple(identityToken: String) async throws -> LoginResult {
        guard !identityToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.decoding
        }
        guard let result = try await APIClient.postForm(
            url: appleLoginURL,
            body: ["identity_token": identityToken],
            sensitiveFields: ["identity_token"],
            as: LoginResult.self
        ), let token = result.resolvedToken,
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.decoding
        }
        return result
    }

    /// 忘记密码
    static func forgetPassword(
        phoneNumber: String,
        code: String,
        password: String
    ) async throws {
        _ = try await APIClient.post(
            path: "login/forget_pwd",
            body: [
                "phonenum": phoneNumber,
                "code": code,
                "password": password
            ],
            as: EmptyResult.self
        )
    }

    /// 邮箱忘记密码：发送验证码
    static func sendModifyEmailCode(email: String) async throws {
        _ = try await APIClient.post(
            path: "user/send_modify_email_code",
            body: ["email": email],
            as: EmptyResult.self
        )
    }

    /// 邮箱忘记密码：修改密码
    static func modifyEmailPassword(
        email: String,
        code: String,
        password: String
    ) async throws {
        _ = try await APIClient.post(
            path: "user/modify_password",
            body: [
                "email": email,
                "code": code,
                "password": password
            ],
            as: EmptyResult.self
        )
    }

    /// 微信授权 code 换取用户信息 / 登录态。对齐 Android `API_WECHAT_LOGIN`。
    static func getWxUserInfo(code: String) async throws -> WeChatLoginResult? {
        try await APIClient.post(
            path: "login/get_wxuser_info",
            body: ["code": code],
            as: WeChatLoginResult.self
        )
    }

    /// 微信未绑定手机号时，手机号验证码绑定并登录。对齐 Android `API_WECHAT_BIND`。
    static func loginByWx(
        phoneNumber: String,
        code: String,
        openid: String,
        nickname: String,
        headimg: String,
        sex: Int
    ) async throws -> WeChatLoginResult? {
        try await APIClient.post(
            path: "login/login_by_wx",
            body: [
                "phonenum": phoneNumber,
                "code": code,
                "openid": openid,
                "nickname": nickname,
                "headimg": headimg,
                "sex": String(sex)
            ],
            as: WeChatLoginResult.self
        )
    }

    /// 对齐 Android `parseChinaIpResult`：兼容 bool / number / string / map。
    static func parseChinaIPResult(_ data: Any?) -> Bool? {
        switch data {
        case let value as Bool:
            return value
        case let value as NSNumber:
            // Bool 在 ObjC bridge 也是 NSNumber，上面 Bool 分支已覆盖真正 Bool。
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue
            }
            return value.intValue != 0
        case let value as String:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "china", "cn", "中国":
                return true
            case "0", "false", "foreign", "overseas", "非中国":
                return false
            default:
                return nil
            }
        case let value as [String: Any]:
            let keys = ["is_china_ip", "is_china", "china", "isChina", "in_china"]
            for key in keys {
                if let nested = value[key], let parsed = parseChinaIPResult(nested) {
                    return parsed
                }
            }
            return nil
        default:
            return nil
        }
    }
}
