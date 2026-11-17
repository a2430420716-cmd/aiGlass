import Foundation

// Compile with the actual AuthService. The API client records requests without
// contacting a server, sending an SMS, signing in or changing an account.
@MainActor
enum APIClient {
    struct Request {
        let path: String
        let body: [String: Any]
        let authorization: String?
    }
    static var lastRequest: Request?

    static func post<T: Decodable>(
        path: String, body: [String: Any], authorization: String? = nil, as type: T.Type
    ) async throws -> T? {
        lastRequest = Request(path: path, body: body, authorization: authorization)
        return nil
    }

    static func postForm<T: Decodable>(
        url: URL, body: [String: String], sensitiveFields: Set<String> = [], as type: T.Type
    ) async throws -> T? { nil }
}

enum BackendRouting {
    static let apiURL = URL(string: "https://example.invalid/api/")!
    static let isChina = true
}
enum APIError: Error { case decoding }
struct EmptyResult: Decodable {}

@main
@MainActor
enum PasswordRecoveryRequestTests {
    static func main() async throws {
        let phone = "13800138000"
        try await AuthService.sendSMS(phoneNumber: phone, type: .forgotPassword)
        let codeRequest = APIClient.lastRequest!
        precondition(codeRequest.path == "login/send_sms", "Recovery must not call authenticated user/send_code")
        precondition(codeRequest.body["phonenum"] as? String == phone)
        precondition(codeRequest.body["type"] as? String == "3", "The recovery purpose is a JSON string")
        precondition(Set(codeRequest.body.keys) == ["phonenum", "type"])
        precondition(codeRequest.authorization == nil, "Sending a recovery code must work before login")

        // Only the backend knows the old password and can validate reuse.
        try await AuthService.forgetPassword(phoneNumber: phone, code: "123456", password: "OldPassword1")
        let resetRequest = APIClient.lastRequest!
        precondition(resetRequest.path == "login/forget_pwd", "Recovery must not call authenticated user/change_pwd")
        precondition(resetRequest.body["phonenum"] as? String == phone)
        precondition(resetRequest.body["code"] as? String == "123456")
        precondition(resetRequest.body["password"] as? String == "OldPassword1")
        precondition(Set(resetRequest.body.keys) == ["phonenum", "code", "password"])
        precondition(resetRequest.authorization == nil, "Resetting a forgotten password must work before login")
        print("Password recovery request tests passed")
    }
}
