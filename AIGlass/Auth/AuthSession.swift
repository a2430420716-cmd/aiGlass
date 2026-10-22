import Combine
import Foundation
import UIKit

@MainActor
final class AuthSession: ObservableObject {
    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var phoneNumber: String?
    @Published private(set) var token: String?
    @Published private(set) var userInfo: UserInfo?
    /// Session-owned selection survives HomeView recreation and server list reordering.
    @Published var selectedHomeDeviceKey: String?
    @Published private(set) var isLoadingUserInfo = false
    @Published private(set) var userInfoError: String?
    @Published private(set) var avatarCacheToken = ""
    /// 刚上传的头像本地图，保证回「我的」立即显示，不依赖远端/缓存。
    @Published private(set) var localAvatarImage: UIImage?
    @Published private(set) var problemFAQItems: [ProblemItem] = []

    private let phoneKey = "auth.phoneNumber"
    private let tokenKey = "auth.token"
    private let loggedInKey = "auth.isLoggedIn"

    /// 进行中的 userinfo 请求对应的 token；换 token / 登出后旧回包一律丢弃。
    private var inFlightUserInfoToken: String?
    private var userInfoRefreshGeneration = 0

    init() {
        let defaults = UserDefaults.standard
        let savedPhone = defaults.string(forKey: phoneKey)
        let savedToken = defaults.string(forKey: tokenKey)
        let savedLoggedIn = defaults.bool(forKey: loggedInKey)
        // Apple/微信登录可能没有手机号；登录态应由服务端 token 恢复。
        let restored = savedLoggedIn && !(savedToken ?? "").isEmpty
        isLoggedIn = restored
        phoneNumber = restored && !(savedPhone ?? "").isEmpty ? savedPhone : nil
        token = restored ? savedToken : nil

        if restored {
            if defaults.string(forKey: BackendRouting.accountOriginKey) == nil {
                // Preserve the business API origin used by earlier app releases.
                defaults.set(BackendRouting.domesticOrigin, forKey: BackendRouting.accountOriginKey)
                defaults.set(BackendRouting.domesticOrigin, forKey: BackendRouting.selectedOriginKey)
            }
            print("[Auth] restored session phone=\(savedPhone ?? "") token=\(token != nil)")
            Task { await refreshUserInfo() }
        } else {
            print("[Auth] no saved session")
        }
    }

    /// 首页设备卡片：始终包含「查找您的设备」；无绑定设备时仅展示该卡片。
    var homeDeviceCards: [DeviceCardData] {
        let devices = userInfo?.device ?? []
        var cards = devices.map(DeviceCardData.init(device:))
        cards.append(.findDevice)
        return cards
    }

    func applyLogin(phoneNumber: String, result: LoginResult?) {
        // 作废登录前可能还在飞的旧 userinfo，避免旧「未登录」把新会话踢掉。
        invalidateInFlightUserInfoRefresh(reason: "applyLogin")

        BackendRouting.pinAccountOrigin()
        let normalizedAccount = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phoneNumber = normalizedAccount.isEmpty ? nil : normalizedAccount
        self.token = result?.resolvedToken
        self.isLoggedIn = true
        self.userInfo = nil
        self.selectedHomeDeviceKey = nil
        self.userInfoError = nil
        self.localAvatarImage = nil
        self.avatarCacheToken = ""

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: loggedInKey)
        if normalizedAccount.isEmpty {
            defaults.removeObject(forKey: phoneKey)
        } else {
            defaults.set(normalizedAccount, forKey: phoneKey)
        }
        if let token = result?.resolvedToken, !token.isEmpty {
            defaults.set(token, forKey: tokenKey)
        } else {
            defaults.removeObject(forKey: tokenKey)
            print("[Auth] login missing token, cannot load devices")
        }
        defaults.synchronize()
        print("[Auth] login saved phone=\(phoneNumber) token=\(self.token != nil)")

        Task { await refreshUserInfo() }
    }

    /// 使用已解析 token 直接建立登录态（微信登录已绑定手机号场景）。
    /// `phoneNumber` 可为空，后续 `refreshUserInfo` 会用 userinfo.phone 回填。
    func applyLogin(phoneNumber: String, token: String?) {
        invalidateInFlightUserInfoRefresh(reason: "applyLogin(token)")
        BackendRouting.pinAccountOrigin()

        self.phoneNumber = phoneNumber.isEmpty ? nil : phoneNumber
        self.token = token
        self.isLoggedIn = true
        self.userInfo = nil
        self.selectedHomeDeviceKey = nil
        self.userInfoError = nil
        self.localAvatarImage = nil
        self.avatarCacheToken = ""

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: loggedInKey)
        if !phoneNumber.isEmpty {
            defaults.set(phoneNumber, forKey: phoneKey)
        }
        if let token, !token.isEmpty {
            defaults.set(token, forKey: tokenKey)
        } else {
            defaults.removeObject(forKey: tokenKey)
            print("[Auth] wechat login missing token, cannot load devices")
        }
        defaults.synchronize()
        print("[Auth] wechat login saved phone=\(phoneNumber) token=\(self.token != nil)")

        Task { await refreshUserInfo() }
    }

    /// `userinfo` 返回的 App 更新信息，登录后缓存在内存。
    var appInfo: AppVersionInfo? {
        userInfo?.appInfo
    }

    var hasAppUpdateAvailable: Bool {
        guard let serverVersion = appInfo?.version
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !serverVersion.isEmpty else {
            return false
        }
        return FirmwareVersionComparator.isServerVersionNewer(
            serverVersion,
            than: AppBundleInfo.shortVersion
        )
    }

    func refreshUserInfo() async {
        guard isLoggedIn else { return }
        guard let requestToken = token, !requestToken.isEmpty else {
            print("[Auth] refreshUserInfo skipped: missing token, force logout")
            logout()
            return
        }

        // 同 token 已有请求在飞：等它结束即可，避免并发双请求互相覆盖/误 logout。
        if inFlightUserInfoToken == requestToken, isLoadingUserInfo {
            print("[Auth] refreshUserInfo join in-flight for same token")
            while isLoadingUserInfo, inFlightUserInfoToken == requestToken, token == requestToken {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return
        }

        let generation = userInfoRefreshGeneration
        inFlightUserInfoToken = requestToken
        isLoadingUserInfo = true
        userInfoError = nil
        defer {
            if userInfoRefreshGeneration == generation {
                isLoadingUserInfo = false
                if inFlightUserInfoToken == requestToken {
                    inFlightUserInfoToken = nil
                }
            }
        }

        do {
            let info = try await UserService.fetchUserInfo(token: requestToken)
            guard userInfoRefreshGeneration == generation, token == requestToken else {
                print("[Auth] ignore stale userInfo success devices=\(info.device.count)")
                return
            }
            userInfo = info
            // 海外邮箱账号 userinfo.phone 可能为空，保留登录时写入的账号标识。
            let resolvedAccount = info.phone.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolvedAccount.isEmpty {
                phoneNumber = resolvedAccount
                UserDefaults.standard.set(resolvedAccount, forKey: phoneKey)
            }
            print("[Auth] userInfo loaded devices=\(info.device.count) nickname=\(info.nickname) appVersion=\(info.appInfo?.version ?? "nil") updateAvailable=\(FirmwareVersionComparator.isServerVersionNewer(info.appInfo?.version ?? "", than: AppBundleInfo.shortVersion)) firmwareKeys=\(info.firmwareBySerialNumber.keys.sorted()) bluetoothKeys=\(info.bluetoothBySerialNumber.keys.sorted())")
            if info.device.isEmpty {
                print("[Auth] userInfo device list empty — check [userinfo] raw JSON")
            }
        } catch {
            guard userInfoRefreshGeneration == generation, token == requestToken else {
                print("[Auth] ignore stale userInfo error: \(error.localizedDescription)")
                return
            }
            let message = error.localizedDescription
            userInfoError = message
            print("[Auth] userInfo failed: \(message)")
            if isSessionInvalidError(message) {
                print("[Auth] session invalid, force logout")
                logout()
            }
        }
    }

    private func invalidateInFlightUserInfoRefresh(reason: String) {
        userInfoRefreshGeneration += 1
        inFlightUserInfoToken = nil
        isLoadingUserInfo = false
        print("[Auth] invalidate in-flight userInfo reason=\(reason) gen=\(userInfoRefreshGeneration)")
    }

    /// 服务端返回未登录等会话失效错误时，清本地态并回登录页。
    private func isSessionInvalidError(_ message: String) -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "未登录" || text.contains("未登录")
    }

    /// 绑定设备成功后刷新用户信息，更新首页设备列表。
    /// 「设备已绑定」直接抛错，不做解绑重绑。
    func bindDeviceAndRefresh(_ request: BindDeviceRequest) async throws {
        guard let token, !token.isEmpty else {
            throw APIError.server(message: L10n.t("登录凭证缺失，请重新登录", "Session expired. Please sign in again"), code: -1)
        }

        try await DeviceService.bindDevice(request, token: token)
        print("[Auth] bind device success sn=\(request.sn) name=\(request.deviceName)")
        await refreshUserInfo()
        guard self.token == token, isLoggedIn else { return }
        selectedHomeDeviceKey = request.serialNumber
    }

    /// 服务端「该设备已绑定用户」类错误。
    static func isDeviceAlreadyBoundError(_ error: Error) -> Bool {
        let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.contains("已绑定用户")
            || message.contains("该设备已绑定")
            || message.localizedCaseInsensitiveContains("already bound")
    }

    /// 解绑设备成功后刷新用户信息。
    /// - Parameters:
    ///   - serialNumber: 蓝牙标识（`serial_number`）
    ///   - sn: 设备硬件 SN（新增 `sn` 字段）
    func unbindDevice(serialNumber: String, sn: String) async throws {
        guard let token, !token.isEmpty else {
            throw APIError.server(message: L10n.t("登录凭证缺失，请重新登录", "Session expired. Please sign in again"), code: -1)
        }

        try await DeviceService.unbindDevice(serialNumber: serialNumber, sn: sn, token: token)
        print("[Auth] unbind device success serial_number=\(serialNumber) sn=\(sn)")
        await refreshUserInfo()
    }

    func setLocalAvatarImage(_ image: UIImage?) {
        localAvatarImage = image
    }

    func uploadAvatarImage(_ imageData: Data) async throws -> String {
        guard let token, !token.isEmpty else {
            throw APIError.server(message: L10n.t("登录凭证缺失，请重新登录", "Session expired. Please sign in again"), code: -1)
        }
        return try await UserService.uploadAvatarImage(imageData, token: token)
    }

    func saveUserProfile(nickname: String, headimg: String) async throws {
        guard let token, !token.isEmpty else {
            throw APIError.server(message: L10n.t("登录凭证缺失，请重新登录", "Session expired. Please sign in again"), code: -1)
        }
        let previousHeadimg = userInfo?.headimg
        let savedHeadimg = UserService.headimgValueForSave(headimg)
        try await UserService.saveUser(nickname: nickname, headimg: headimg, token: token)
        if let current = userInfo {
            userInfo = current.updating(nickname: nickname, headimg: savedHeadimg)
        }
        // 仅设置成功时清一次旧缓存，随后写入新图；之后加载走缓存不再 purge
        AvatarImageCache.purge(headimgs: previousHeadimg, savedHeadimg, headimg)
        if let localAvatarImage {
            AvatarImageCache.store(image: localAvatarImage, headimg: savedHeadimg)
            AvatarImageCache.store(image: localAvatarImage, headimg: headimg)
        }
        if !savedHeadimg.isEmpty {
            avatarCacheToken = UUID().uuidString
        }
        await refreshUserInfo()
        if let current = userInfo {
            let serverHeadimg = current.headimg.trimmingCharacters(in: .whitespacesAndNewlines)
            let serverPath = UserService.headimgValueForSave(serverHeadimg)
            // 服务端空/旧值时保留刚保存路径；同路径则优先服务端完整 URL
            if !savedHeadimg.isEmpty, serverHeadimg.isEmpty || serverPath != savedHeadimg {
                userInfo = current.updating(nickname: nickname, headimg: savedHeadimg)
            } else if current.nickname != nickname {
                userInfo = current.updating(nickname: nickname)
            }
            if let localAvatarImage {
                AvatarImageCache.store(image: localAvatarImage, headimg: userInfo?.headimg)
            }
        }
    }

    func refreshProblemFAQList() async {
        guard let token, !token.isEmpty else {
            print("[get_problem_list] skipped: missing token")
            return
        }

        do {
            problemFAQItems = try await ProblemService.fetchProblemList(token: token)
        } catch {
            print("[get_problem_list] failed: \(error.localizedDescription)")
        }
    }

    /// 注销账号：调用 signout 接口成功后清本地登录态。对齐 Android。
    func signOutAccount() async throws {
        guard let token, !token.isEmpty else {
            throw APIError.server(message: L10n.t("登录凭证缺失，请重新登录", "Session expired. Please sign in again"), code: -1)
        }
        try await UserService.signOut(token: token)
        print("[Auth] account signout success")
        logout()
    }

    func unbindWeChat() async throws {
        guard let token, !token.isEmpty else {
            throw APIError.server(message: L10n.t("登录凭证缺失，请重新登录", "Session expired. Please sign in again"), code: -1)
        }
        try await UserService.unbindWeChat(token: token)
        await refreshUserInfo()
    }

    /// 退出登录：清除本地登录态与用户信息，回到登录页。
    func logout() {
        invalidateInFlightUserInfoRefresh(reason: "logout")
        userInfoError = nil
        userInfo = nil
        selectedHomeDeviceKey = nil
        phoneNumber = nil
        token = nil
        isLoggedIn = false
        localAvatarImage = nil
        avatarCacheToken = ""
        problemFAQItems = []
        // 对齐 Android：换号后清掉内存聊天，避免串历史。
        AIChatSession.shared.clear()

        let defaults = UserDefaults.standard
        defaults.set(false, forKey: loggedInKey)
        defaults.removeObject(forKey: phoneKey)
        defaults.removeObject(forKey: tokenKey)
        defaults.removeObject(forKey: BackendRouting.accountOriginKey)
        defaults.synchronize()
        print("[Auth] logged out")
    }
}
