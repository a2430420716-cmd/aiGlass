import SwiftUI

/// 微信授权后未绑定手机号时，用手机号验证码完成绑定登录。
/// 对齐 Android `WechatBindActivity`（login_by_wx）。
struct WeChatBindView: View {
    let openid: String
    let nickname: String
    let headimg: String
    let sex: Int

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession

    @State private var phoneNumber = ""
    @State private var verificationCode = ""
    @State private var countdown = 0
    @State private var isSendingCode = false
    @State private var isBinding = false
    @State private var alertMessage: String?
    @State private var countdownTask: Task<Void, Never>?

    private var isPhoneValid: Bool {
        phoneNumber.count == 11 && phoneNumber.allSatisfy(\.isNumber)
    }

    private var canSendCode: Bool {
        isPhoneValid && countdown == 0 && !isSendingCode
    }

    private var canBind: Bool {
        isPhoneValid && verificationCode.count == 6 && !isBinding
    }

    private var placeholderColor: Color {
        Color(red: 0.45, green: 0.45, blue: 0.45)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            VStack(spacing: 16) {
                phoneField
                codeField

                bindButton
                    .padding(.top, 8)

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .onDisappear {
            countdownTask?.cancel()
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("绑定手机号", "Bind Phone"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button {
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

    private var phoneField: some View {
        TextField(
            "",
            text: $phoneNumber,
            prompt: Text(L10n.t("请输入手机号", "Phone number"))
                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                .foregroundColor(placeholderColor)
        )
        .keyboardType(.numberPad)
        .textContentType(.telephoneNumber)
        .font(AppTheme.notoSansSC(size: 16, weight: .regular))
        .foregroundStyle(AppTheme.primaryText)
        .onChangeCompat(of: phoneNumber) { newValue in
            let filtered = newValue.filter(\.isNumber)
            if filtered.count > 11 {
                phoneNumber = String(filtered.prefix(11))
            } else if filtered != newValue {
                phoneNumber = filtered
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var codeField: some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: $verificationCode,
                prompt: Text(L10n.t("请输入验证码", "Code"))
                    .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                    .foregroundColor(placeholderColor)
            )
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(AppTheme.notoSansSC(size: 16, weight: .regular))
            .foregroundStyle(AppTheme.primaryText)
            .onChangeCompat(of: verificationCode) { newValue in
                let filtered = newValue.filter(\.isNumber)
                if filtered.count > 6 {
                    verificationCode = String(filtered.prefix(6))
                } else if filtered != newValue {
                    verificationCode = filtered
                }
            }

            Button {
                sendCode()
            } label: {
                if isSendingCode {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 88)
                } else if countdown > 0 {
                    Text("\(countdown)s")
                        .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                        .foregroundStyle(placeholderColor)
                        .frame(minWidth: 88)
                } else {
                    Text(L10n.t("发送验证码", "Send code"))
                        .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                        .foregroundStyle(canSendCode ? AppTheme.primaryText : placeholderColor)
                        .frame(minWidth: 88)
                }
            }
            .disabled(!canSendCode)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var bindButton: some View {
        Button {
            bind()
        } label: {
            ZStack {
                Text(L10n.t("绑定并登录", "Bind & Log In"))
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .opacity(isBinding ? 0 : 1)

                if isBinding {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(canBind ? Color(red: 0.20, green: 0.20, blue: 0.20) : Color(red: 0.70, green: 0.70, blue: 0.70))
            .clipShape(Capsule())
        }
        .disabled(!canBind)
    }

    private func sendCode() {
        guard canSendCode else {
            if !isPhoneValid { alertMessage = L10n.t("请输入正确的手机号", "Enter a valid phone number") }
            return
        }
        let account = phoneNumber
        isSendingCode = true
        Task {
            do {
                try await AuthService.sendSMS(phoneNumber: account, type: .login)
                await MainActor.run {
                    isSendingCode = false
                    startCountdown()
                }
            } catch {
                await MainActor.run {
                    isSendingCode = false
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func bind() {
        guard canBind else { return }
        let account = phoneNumber
        let code = verificationCode
        isBinding = true
        Task {
            do {
                let result = try await AuthService.loginByWx(
                    phoneNumber: account,
                    code: code,
                    openid: openid,
                    nickname: nickname,
                    headimg: headimg,
                    sex: sex
                )
                guard let token = result?.resolvedToken else {
                    await MainActor.run {
                        isBinding = false
                        alertMessage = L10n.t("绑定失败，请重试", "Bind failed, please try again")
                    }
                    return
                }
                await MainActor.run {
                    isBinding = false
                    authSession.applyLogin(phoneNumber: account, token: token)
                }
            } catch {
                await MainActor.run {
                    isBinding = false
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 60
        countdownTask = Task { @MainActor in
            for remaining in stride(from: 59, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                countdown = remaining
            }
        }
    }
}

#Preview {
    CompatibleNavigationStack {
        WeChatBindView(openid: "demo", nickname: "", headimg: "", sex: 0)
            .environmentObject(AuthSession())
    }
}
