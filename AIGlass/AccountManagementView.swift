import SwiftUI

struct AccountManagementView: View {
    private enum MenuKey: String, CaseIterable {
        case changePassword = "修改密码"
        case thirdPartyBinding = "第三方账号绑定"
        case signOut = "注销账号"

        @MainActor
        var title: String {
            switch self {
            case .changePassword: return L10n.t("修改密码", "Change password")
            case .thirdPartyBinding: return L10n.t("第三方账号绑定", "Linked accounts")
            case .signOut: return L10n.t("注销账号", "Delete account")
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Binding var showsTabBar: Bool
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var pairingCoordinator: PairingCoordinator
    @ObservedObject private var languageManager = AppLanguageManager.shared

    @State private var showsChangePassword = false
    @State private var showsThirdPartyBinding = false
    @State private var showsSignOutConfirm = false
    @State private var showsDevicesRequired = false
    @State private var showsForceUnbindConfirm = false
    @State private var showsFinalSignOutWarning = false
    @State private var isSigningOut = false
    @State private var isUnbindingDevice = false
    @State private var toastMessage: String?
    @State private var alertMessage: String?
    @State private var pendingUnbindDevices: [UserDevice] = []
    @State private var pendingUnbindIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(MenuKey.allCases, id: \.self) { key in
                        switch key {
                        case .changePassword:
                            Button {
                                showsChangePassword = true
                            } label: {
                                AccountMenuRowContent(title: key.title)
                            }
                            .buttonStyle(.plain)
                        case .signOut:
                            Button {
                                showsSignOutConfirm = true
                            } label: {
                                AccountMenuRowContent(title: key.title)
                            }
                            .buttonStyle(.plain)
                            .disabled(isSigningOut)
                        case .thirdPartyBinding:
                            Button {
                                openThirdPartyBinding()
                            } label: {
                                AccountMenuRowContent(title: key.title)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .overlay {
            if isUnbindingDevice {
                ZStack {
                    Color.black.opacity(0.22).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(AppTheme.primaryText)
                        Text(L10n.t("正在解绑...", "Unbinding..."))
                            .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 22)
                    .background(AppTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Color.black.opacity(0.78))
                    .clipShape(Capsule())
                    .padding(.bottom, 42)
            }
        }
        .navigationBarHidden(true)
        .compatibleNavigationDestination(isPresented: $showsChangePassword) {
            ChangePasswordView()
        }
        .compatibleNavigationDestination(isPresented: $showsThirdPartyBinding) {
            WeChatAccountBindingView()
                .environmentObject(authSession)
        }
        .compatibleNavigationDestination(isPresented: $showsFinalSignOutWarning) {
            AccountSignOutConfirmView(
                isSigningOut: isSigningOut,
                onConfirm: performFinalSignOut
            )
        }
        .alert(L10n.t("注销账号", "Delete account"), isPresented: $showsSignOutConfirm) {
            Button(L10n.t("保留账号", "Keep Account"), role: .cancel) {}
            Button(L10n.t("注销", "Delete"), role: .destructive) {
                startSignOutAfterUnbindingDevices()
            }
        } message: {
            Text(L10n.t(
                "确定要注销当前账号吗？注销后将无法恢复。",
                "Delete the current account? This action cannot be undone."
            ))
        }
        .alert(
            L10n.t("注销账号前请先解除设备配对", "Please unpair your device before deleting your account."),
            isPresented: $showsDevicesRequired
        ) {
            Button(L10n.t("确定", "OK")) {
                unbindNextDevice()
            }
        }
        .alert(forceUnbindTitle, isPresented: $showsForceUnbindConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {
                cancelSignOutFlow()
            }
            Button(L10n.t("强制解绑", "Force unbind"), role: .destructive) {
                performPendingDeviceUnbind(force: true)
            }
        } message: {
            Text(L10n.t(
                "设备未连接状态下，强制解绑无法清空数据，存在数据泄露风险，请谨慎操作。",
                "When the device is offline, force unbinding cannot clear its data and may expose data. Please proceed carefully."
            ))
        }
        .overlay {
            if pairingCoordinator.isWaitingForUnpairFactoryReset { UnpairFactoryResetProgressView() }
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .onAppear {
            showsTabBar = false
        }
        .onDisappear {
            if !showsChangePassword && !showsThirdPartyBinding && !showsFinalSignOutWarning {
                showsTabBar = true
            }
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("账号管理", "Account management"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button {
                    showsTabBar = true
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 44, alignment: .leading)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var pendingUnbindDevice: UserDevice? {
        guard pendingUnbindIndex < pendingUnbindDevices.count else { return nil }
        return pendingUnbindDevices[pendingUnbindIndex]
    }

    private func openThirdPartyBinding() {
        Task {
            await authSession.refreshUserInfo()
            let openid = authSession.userInfo?.openid
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if openid.isEmpty {
                alertMessage = L10n.t("当前账号未关联微信", "No WeChat account linked")
            } else {
                showsThirdPartyBinding = true
            }
        }
    }

    private var forceUnbindTitle: String {
        let name = pendingUnbindDevice?.displayName ?? "MOCO"
        return L10n.t("确认强制解绑“\(name)”？", "Force unbind \"\(name)\"?")
    }

    private func startSignOutAfterUnbindingDevices() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            await authSession.refreshUserInfo()
            guard authSession.isLoggedIn else { return }
            if let error = authSession.userInfoError {
                isSigningOut = false
                alertMessage = error
                return
            }

            pendingUnbindDevices = authSession.userInfo?.device ?? []
            pendingUnbindIndex = 0
            isSigningOut = false
            if pendingUnbindDevices.isEmpty {
                showsFinalSignOutWarning = true
            } else {
                showsDevicesRequired = true
            }
        }
    }

    private func unbindNextDevice() {
        guard pendingUnbindDevice != nil else {
            pendingUnbindDevices = []
            pendingUnbindIndex = 0
            showsFinalSignOutWarning = true
            return
        }

        if isPendingDeviceConnected {
            performPendingDeviceUnbind()
        } else {
            showsForceUnbindConfirm = true
        }
    }

    private var isPendingDeviceConnected: Bool {
        guard let device = pendingUnbindDevice else { return false }
        let ble = pairingCoordinator.astraA1BleManager
        // Cloud connection and a saved UUID can outlive power-off. Only a ready
        // local transport matching this exact card can perform a factory reset.
        return ble.isDeviceAvailable && ble.matchesCurrentDevice(
            serialNumber: device.serialNumber, hardwareSN: device.hardwareSN
        )
    }

    private func performPendingDeviceUnbind(force: Bool = false) {
        guard let device = pendingUnbindDevice else {
            unbindNextDevice()
            return
        }
        guard !isSigningOut else { return }

        let serialNumber = device.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedSN = pairingCoordinator.astraA1BleManager
            .cachedHardwareSN(forSerialNumber: serialNumber)
        let sn = nonEmpty(device.hardwareSN) ?? nonEmpty(cachedSN) ?? ""

        isSigningOut = true
        isUnbindingDevice = true
        DebugLogStore.logConnect("unbind: account deletion confirmed", detail: "target=\(serialNumber) forced=\(force) localTargetAvailable=\(isPendingDeviceConnected) cloudConnectionIgnored=true hasHardwareSN=\(!sn.isEmpty)")
        Task {
            do {
                try await pairingCoordinator.unpairDevice(serialNumber: serialNumber, sn: sn, force: force)
                isUnbindingDevice = false
                isSigningOut = false
                showToast(L10n.t("设备已解除配对", "Device unpaired"))
                try? await Task.sleep(nanoseconds: 700_000_000)
                pendingUnbindIndex += 1
                unbindNextDevice()
            } catch {
                isUnbindingDevice = false
                isSigningOut = false
                alertMessage = error.localizedDescription
            }
        }
    }

    private func performFinalSignOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            do {
                try await authSession.signOutAccount()
                isSigningOut = false
                // 账号注销完成后不再保留设备会话。
                pairingCoordinator.resetForLogout(keepDeviceConnection: false)
                showsTabBar = true
                dismiss()
            } catch {
                isSigningOut = false
                alertMessage = error.localizedDescription
            }
        }
    }

    private func cancelSignOutFlow() {
        pendingUnbindDevices = []
        pendingUnbindIndex = 0
        isSigningOut = false
        isUnbindingDevice = false
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func normalized(_ value: String?) -> String? {
        nonEmpty(value)?.lowercased()
    }
}

private struct AccountSignOutConfirmView: View {
    @Environment(\.dismiss) private var dismiss
    private let warningColor = Color(red: 1, green: 0, blue: 0)
    let isSigningOut: Bool
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    HStack(alignment: .top, spacing: 14) {
                        Image("android_account_signout_warning")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)

                        Text(L10n.t(
                            "账号一经注销，将无法恢复，请认真阅读以下说明",
                            "Account deletion is irreversible. Please read the following carefully."
                        ))
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(warningColor)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(L10n.t(
                        "账号注销后，你将无法再使用该账号，包括但不限于：\n1. 无法登录账号，并移除该账号下的所有登录方式；\n2. 个人资料和文件资料将被清空，并无法找回；\n3. 取消所有第三方平台的关联身份（如微信）。",
                        "After deleting your account, you will no longer be able to use it, including:\n1. You will not be able to sign in, and all login methods linked to this account will be removed;\n2. Your profile and files will be permanently erased and cannot be recovered;\n3. All third-party account links, such as WeChat, will be removed."
                    ))
                    .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineSpacing(7)
                }
                .padding(.horizontal, 20)
                .padding(.top, 32)
            }

            Button(action: onConfirm) {
                Group {
                    if isSigningOut {
                        ProgressView().tint(.white)
                    } else {
                        Text(L10n.t("确认注销", "Confirm Deletion"))
                            .font(AppTheme.notoSansSC(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(warningColor)
                .clipShape(Capsule())
            }
            .disabled(isSigningOut)
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("注销账号", "Delete account"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button { dismiss() } label: {
                    Image("android_settings_back")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 21, height: 21)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private struct AccountMenuRow: View {
    let title: String

    var body: some View {
        Button {} label: {
            AccountMenuRowContent(title: title)
        }
        .buttonStyle(.plain)
    }
}

private struct AccountMenuRowContent: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct WeChatAccountBindingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession
    @State private var showsConfirm = false
    @State private var isUnbinding = false
    @State private var alertMessage: String?

    private var hasBoundWeChat: Bool {
        !(authSession.userInfo?.openid
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(L10n.t("第三方账号绑定", "Linked accounts"))
                    .font(AppTheme.notoSansSC(size: 18, weight: .bold))

                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(AppTheme.primaryText)
                            .frame(width: 44, height: 44, alignment: .leading)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if hasBoundWeChat {
                HStack(spacing: 14) {
                    Image("android_wechat")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)

                    Text(L10n.t("微信", "WeChat"))
                        .font(AppTheme.notoSansSC(size: 16, weight: .regular))

                    Spacer()

                    Button(L10n.t("解除关联", "Unlink")) {
                        showsConfirm = true
                    }
                    .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .frame(height: 32)
                    .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                    .clipShape(Capsule())
                    .disabled(isUnbinding)
                }
                .padding(.horizontal, 20)
                .frame(height: 65)
                .background(AppTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 35)
            }

            Spacer()
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .alert(L10n.t("解除微信关联", "Unlink WeChat"), isPresented: $showsConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("确定", "OK"), role: .destructive) { unbind() }
        } message: {
            Text(L10n.t("解除后将无法使用该微信账号登录当前账号，确定要解除关联吗？", "After unlinking, this WeChat account can no longer be used to sign in to the current account. Continue?"))
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func unbind() {
        guard !isUnbinding else { return }
        isUnbinding = true
        Task {
            do {
                try await authSession.unbindWeChat()
                isUnbinding = false
                dismiss()
            } catch {
                isUnbinding = false
                alertMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    CompatibleNavigationStack {
        AccountManagementView(showsTabBar: .constant(false))
            .environmentObject(AuthSession())
            .environmentObject(PairingCoordinator())
    }
}
