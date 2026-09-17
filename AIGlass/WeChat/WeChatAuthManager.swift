import Foundation
import UIKit

#if canImport(WechatOpenSDK)
import WechatOpenSDK
#endif

/// 微信授权错误。对齐 Android `WeChatLoginManager.AuthResult`。
enum WeChatAuthError: LocalizedError {
    /// 未集成微信 SDK（未链接 WechatOpenSDK.xcframework）。
    case sdkMissing
    /// 未安装微信客户端。
    case notInstalled
    /// 用户取消授权。
    case cancelled
    /// 发起授权失败或返回错误。
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .sdkMissing:
            return L10n.t("微信 SDK 未集成", "WeChat SDK not integrated")
        case .notInstalled:
            return L10n.t("请先安装微信客户端", "Please install WeChat first")
        case .cancelled:
            return L10n.t("已取消微信授权", "WeChat authorization cancelled")
        case .failed(let message):
            return message.isEmpty ? L10n.t("微信授权失败", "WeChat authorization failed") : message
        }
    }
}

/// 微信登录管理：注册 App、发起授权、处理回调。
/// 对齐 Android `WeChatLoginManager`（APP_ID = wxb4a02f227c66b655）。
///
/// 未链接 `WechatOpenSDK` 时全部方法给出 `WeChatAuthError.sdkMissing`，保证工程可编译；
/// 集成 SDK（SPM `WechatOpenSDK` 或 `Vendor/WechatOpenSDK.xcframework`）后自动走真实实现。
final class WeChatAuthManager: NSObject {
    static let shared = WeChatAuthManager()

    /// 微信开放平台 AppID，与 Android / Info.plist URL Scheme 一致。
    static let appID = "wxb4a02f227c66b655"

    /// Universal Link，必须与开放平台后台填写的值完全一致（含结尾斜杠）。
    /// 后台已配置为 https://glasses.kaimou.net/app/ ；
    /// https://glasses.kaimou.net/.well-known/apple-app-site-association 声明
    /// appID = G8X6YGC2WL.uni.app.UNI03B27DD，paths = ["*"]，已覆盖 /app/ 路径。
    /// SDK 2.0.x 的 `registerApp` 要求非空，否则注册失败、`sendReq` 直接返回 false。
    static let universalLink = "https://glasses.kaimou.net/app/"

    /// 是否已集成 SDK。编译期判定为主，运行期再确认 `WXApi` 类确实链接进来。
    static var isSDKAvailable: Bool {
        #if canImport(WechatOpenSDK)
        return NSClassFromString("WXApi") != nil
        #else
        return false
        #endif
    }

    private var authCompletion: ((Result<String, WeChatAuthError>) -> Void)?
    private var didRegister = false
    private var registerSucceeded = false

    private override init() {
        super.init()
    }

    /// 启动或首次使用前注册 App。多次调用安全。
    /// 未配 Universal Link 时 `registerApp` 可能返回 false，但 URL Scheme 回调仍可用，
    /// 因此注册结果只做日志，不作为「SDK 未集成」的依据。
    @discardableResult
    func registerIfNeeded() -> Bool {
        #if canImport(WechatOpenSDK)
        if didRegister { return registerSucceeded }
        #if DEBUG
        WXApi.startLog(by: .detail) { message in
            print("[WeChatSDK] \(message)")
        }
        #endif
        let ok = WXApi.registerApp(Self.appID, universalLink: Self.universalLink)
        didRegister = true
        registerSucceeded = ok
        print("[WeChat] registerApp ok=\(ok) appID=\(Self.appID) universalLink=\(Self.universalLink.isEmpty ? "<empty>" : Self.universalLink)")
        return ok
        #else
        print("[WeChat] SDK missing, registerApp skipped")
        return false
        #endif
    }

    /// 微信是否已安装。SDK 未集成时返回 false。
    var isWeChatInstalled: Bool {
        #if canImport(WechatOpenSDK)
        registerIfNeeded()
        return WXApi.isWXAppInstalled()
        #else
        return false
        #endif
    }

    /// 发起微信授权登录。回调返回授权 `code` 或错误。
    func sendAuth(completion: @escaping (Result<String, WeChatAuthError>) -> Void) {
        #if canImport(WechatOpenSDK)
        let registered = registerIfNeeded()
        let installed = WXApi.isWXAppInstalled()
        let supported = WXApi.isWXAppSupport()
        print("[WeChat] sendAuth registered=\(registered) installed=\(installed) supportApi=\(supported)")
        guard installed else {
            completion(.failure(.notInstalled))
            return
        }
        guard registered else {
            completion(.failure(.failed(L10n.t("微信注册失败，请检查 Universal Link 配置", "WeChat registration failed. Check Universal Link setup"))))
            return
        }
        // 覆盖上一次未完成回调，避免悬挂。
        authCompletion?(.failure(.cancelled))
        authCompletion = completion

        let req = SendAuthReq()
        req.scope = "snsapi_userinfo"
        req.state = "moco_ai_\(Int(Date().timeIntervalSince1970 * 1000))"
        // 带 viewController 的接口：微信不可用时可回退到内置 H5 授权。
        WXApi.sendAuthReq(req, viewController: Self.topViewController(), delegate: self) { [weak self] success in
            print("[WeChat] sendAuthReq success=\(success)")
            if !success {
                self?.finishAuth(.failure(.failed(L10n.t("发起微信授权失败", "Failed to start WeChat authorization"))))
            }
        }
        #else
        completion(.failure(.sdkMissing))
        #endif
    }

    /// AppDelegate / SwiftUI onOpenURL 转发微信回调。
    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        #if canImport(WechatOpenSDK)
        return WXApi.handleOpen(url, delegate: self)
        #else
        return false
        #endif
    }

    /// 微信通过 Universal Link 回跳时的入口。
    @discardableResult
    func handleUserActivity(_ userActivity: NSUserActivity) -> Bool {
        #if canImport(WechatOpenSDK)
        return WXApi.handleOpenUniversalLink(userActivity, delegate: self)
        #else
        return false
        #endif
    }

    /// Universal Link 接入自检，结果只打日志。需在 `registerApp` 成功后调用。
    func checkUniversalLinkReady() {
        #if canImport(WechatOpenSDK)
        guard registerIfNeeded() else {
            print("[WeChat] checkUniversalLink skipped: registerApp failed")
            return
        }
        WXApi.checkUniversalLinkReady { step, result in
            print("[WeChat] ULCheck step=\(step.rawValue) success=\(result.success) errorInfo=\(result.errorInfo ?? "") suggestion=\(result.suggestion ?? "")")
        }
        #endif
    }

    private static func topViewController() -> UIViewController {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? UIViewController()
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    private func finishAuth(_ result: Result<String, WeChatAuthError>) {
        let completion = authCompletion
        authCompletion = nil
        DispatchQueue.main.async {
            completion?(result)
        }
    }
}

#if canImport(WechatOpenSDK)
extension WeChatAuthManager: WXApiDelegate {
    func onReq(_ req: BaseReq) {}

    func onResp(_ resp: BaseResp) {
        guard let authResp = resp as? SendAuthResp else { return }
        print("[WeChat] auth resp errCode=\(authResp.errCode) errStr=\(authResp.errStr ?? "")")
        switch authResp.errCode {
        case WXSuccess.rawValue:
            let code = authResp.code ?? ""
            if code.isEmpty {
                finishAuth(.failure(.failed(authResp.errStr ?? L10n.t("微信授权失败", "WeChat authorization failed"))))
            } else {
                finishAuth(.success(code))
            }
        case WXErrCodeUserCancel.rawValue:
            finishAuth(.failure(.cancelled))
        default:
            finishAuth(.failure(.failed(authResp.errStr ?? L10n.t("微信授权失败", "WeChat authorization failed"))))
        }
    }
}
#endif
