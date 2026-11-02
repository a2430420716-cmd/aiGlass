import SwiftUI

struct ChangePasswordView: View {
    private enum Field: Hashable {
        case code
        case password
        case confirmation
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession
    @FocusState private var focusedField: Field?

    @State private var verificationCode = ""
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var showsPassword = false
    @State private var showsPasswordConfirmation = false
    @State private var countdown = 0
    @State private var isSendingCode = false
    @State private var isSubmitting = false
    @State private var alertMessage: String?
    @State private var showsSuccessToast = false
    @State private var countdownTask: Task<Void, Never>?
    @State private var submitTask: Task<Void, Never>?

    private var accountValue: String {
        authSession.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var isEmailAccount: Bool {
        Self.isValidEmail(accountValue)
    }

    private var isPhoneAccount: Bool {
        accountValue.count == 11 && accountValue.allSatisfy(\.isNumber)
    }

    private var isAccountValid: Bool {
        isEmailAccount || isPhoneAccount
    }

    private var displayedAccountValue: String {
        guard isPhoneAccount else {
            return accountValue.isEmpty ? L10n.t("未获取到账户信息", "No account information found") : accountValue
        }
        return "\(accountValue.prefix(3))****\(accountValue.suffix(4))"
    }

    private var canSendCode: Bool {
        isAccountValid
            && authSession.token?.isEmpty == false
            && countdown == 0
            && !isSendingCode
    }

    private var normalizedVerificationCode: String {
        verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedPassword: String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedPasswordConfirmation: String {
        passwordConfirmation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !normalizedVerificationCode.isEmpty
            && normalizedPassword.count >= 8
            && !normalizedPasswordConfirmation.isEmpty
            && normalizedPassword == normalizedPasswordConfirmation
            && !isSubmitting
            && authSession.token?.isEmpty == false
            && isAccountValid
    }

    private func passwordValidationMessage(for password: String) -> String? {
        let scalars = password.unicodeScalars
        guard (8...18).contains(scalars.count) else {
            return L10n.t("密码长度需为8-18位", "Password must be 8–18 characters")
        }
        guard scalars.allSatisfy({ (33...126).contains(Int($0.value)) }) else {
            return L10n.t("密码不能包含空格或非法字符", "Password cannot contain spaces or invalid characters")
        }

        let hasLetter = scalars.contains {
            (65...90).contains(Int($0.value)) || (97...122).contains(Int($0.value))
        }
        let hasNumber = scalars.contains { (48...57).contains(Int($0.value)) }
        let hasSymbol = scalars.contains {
            let value = Int($0.value)
            return !(48...57).contains(value)
                && !(65...90).contains(value)
                && !(97...122).contains(value)
        }

        guard [hasLetter, hasNumber, hasSymbol].filter({ $0 }).count >= 2 else {
            return L10n.t(
                "密码需至少包含英文、数字、符号中的两种",
                "Password must include at least two of: letters, numbers, symbols"
            )
        }

        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        formFields

                        passwordHint
                            .padding(.top, 14)
                            .padding(.horizontal, 16)

                        Spacer(minLength: 32)

                        submitButton
                            .padding(.horizontal, 16)
                            .padding(.bottom, 120)
                    }
                    .padding(.top, 16)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .compatibleScrollDismissesKeyboard()
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .overlay(alignment: .bottom) {
            if showsSuccessToast {
                Text(L10n.t("密码修改成功", "Password updated"))
                    .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.78))
                    .clipShape(Capsule())
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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
            submitTask?.cancel()
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("修改密码", "Change Password"))
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

    private var formFields: some View {
        VStack(spacing: 10) {
            HStack {
                Text(displayedAccountValue)
                    .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)

                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 52)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $verificationCode,
                    prompt: Text(L10n.t("请输入验证码", "Enter verification code"))
                        .foregroundColor(AppTheme.secondaryText.opacity(0.55))
                )
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .focused($focusedField, equals: .code)
                .onChangeCompat(of: verificationCode) { newValue in
                    let filtered = newValue.filter(\.isNumber)
                    verificationCode = String(filtered.prefix(6))
                }

                Button {
                    sendVerificationCode()
                } label: {
                    if isSendingCode {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 88)
                    } else {
                        Text(countdown > 0
                             ? L10n.t("重新发送（\(countdown)S）", "Resend (\(countdown)S)")
                             : L10n.t("发送验证码", "Send Code"))
                            .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                            .foregroundStyle(
                                canSendCode
                                    ? AppTheme.primaryText
                                    : AppTheme.secondaryText.opacity(0.6)
                            )
                            .frame(minWidth: 88)
                    }
                }
                .disabled(!canSendCode)
            }
            .padding(.horizontal, 24)
            .frame(height: 52)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            passwordField(
                placeholder: L10n.t("至少输入8位新密码", "At least 8 characters"),
                text: $password,
                isVisible: $showsPassword,
                field: .password,
                textContentType: .newPassword
            )

            passwordField(
                placeholder: L10n.t("再次确认新密码", "Confirm new password"),
                text: $passwordConfirmation,
                isVisible: $showsPasswordConfirmation,
                field: .confirmation,
                textContentType: .newPassword
            )
        }
        .padding(.horizontal, 16)
    }

    private func passwordField(
        placeholder: String,
        text: Binding<String>,
        isVisible: Binding<Bool>,
        field: Field,
        textContentType: UITextContentType
    ) -> some View {
        HStack(spacing: 12) {
            Group {
                if isVisible.wrappedValue {
                    TextField(
                        "",
                        text: text,
                        prompt: Text(placeholder)
                            .foregroundColor(AppTheme.secondaryText.opacity(0.55))
                    )
                } else {
                    SecureField(
                        "",
                        text: text,
                        prompt: Text(placeholder)
                            .foregroundColor(AppTheme.secondaryText.opacity(0.55))
                    )
                }
            }
            .textContentType(textContentType)
            .font(AppTheme.notoSansSC(size: 16, weight: .regular))
            .foregroundStyle(AppTheme.primaryText)
            .focused($focusedField, equals: field)
            .onChangeCompat(of: text.wrappedValue) { newValue in
                if newValue.unicodeScalars.count > 18 {
                    text.wrappedValue = String(newValue.unicodeScalars.prefix(18))
                }
            }

            Button {
                isVisible.wrappedValue.toggle()
            } label: {
                Image(isVisible.wrappedValue ? "android_password_visible" : "android_password_hidden")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .frame(width: 28, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible.wrappedValue
                                ? L10n.t("隐藏密码", "Hide password")
                                : L10n.t("显示密码", "Show password"))
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var passwordHint: some View {
        Text(L10n.t(
            "请输入8-18位密码，支持英文、数字、符号，至少包含其中两种，不能包含空格",
            "Enter an 8–18 character password with letters, numbers, or symbols. Include at least two types. No spaces."
        ))
            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var submitButton: some View {
        Button {
            changePassword()
        } label: {
            ZStack {
                Text(L10n.t("修改密码", "Change Password"))
                    .font(AppTheme.notoSansSC(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .opacity(isSubmitting ? 0 : 1)

                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                canSubmit
                    ? Color(red: 0.20, green: 0.20, blue: 0.20)
                    : Color(red: 0.80, green: 0.80, blue: 0.80)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    private func sendVerificationCode() {
        guard canSendCode, let token = authSession.token else {
            if accountValue.isEmpty {
                alertMessage = L10n.t("未获取到账户信息", "No account information found")
            } else if !isAccountValid {
                alertMessage = accountValue.contains("@")
                    ? L10n.t("请输入正确的邮箱", "Enter a valid email")
                    : L10n.t("请输入正确的手机号", "Enter a valid phone number")
            } else if authSession.token?.isEmpty != false {
                alertMessage = L10n.t("登录凭证缺失，请重新登录", "Session expired. Please sign in again")
            }
            return
        }

        focusedField = nil
        isSendingCode = true

        Task {
            do {
                if isEmailAccount {
                    try await UserService.sendEmailPasswordChangeCode(
                        email: accountValue,
                        token: token
                    )
                } else {
                    try await UserService.sendPasswordChangeCode(
                        phoneNumber: accountValue,
                        token: token
                    )
                }
                isSendingCode = false
                startCountdown()
            } catch {
                isSendingCode = false
                alertMessage = error.localizedDescription
            }
        }
    }

    private func changePassword() {
        guard let token = authSession.token, !token.isEmpty else {
            alertMessage = L10n.t("登录凭证缺失，请重新登录", "Session expired. Please sign in again")
            return
        }

        let code = normalizedVerificationCode
        let newPassword = normalizedPassword
        let confirmPassword = normalizedPasswordConfirmation

        guard isAccountValid else {
            alertMessage = accountValue.contains("@")
                ? L10n.t("请输入正确的邮箱", "Enter a valid email")
                : L10n.t("请输入正确的手机号", "Enter a valid phone number")
            return
        }

        guard !code.isEmpty else {
            alertMessage = L10n.t("请输入验证码", "Enter verification code")
            return
        }

        guard !newPassword.isEmpty, !confirmPassword.isEmpty else {
            alertMessage = L10n.t("请输入新密码", "Enter a new password")
            return
        }

        guard newPassword == confirmPassword else {
            alertMessage = L10n.t("两次输入的密码不一致", "Passwords do not match")
            return
        }

        if let message = passwordValidationMessage(for: newPassword) {
            alertMessage = message
            return
        }

        guard !isSubmitting else { return }

        focusedField = nil
        isSubmitting = true

        submitTask = Task {
            do {
                if isEmailAccount {
                    try await UserService.changeEmailPassword(
                        email: accountValue,
                        code: code,
                        password: newPassword,
                        token: token
                    )
                } else {
                    try await UserService.changePassword(
                        phoneNumber: accountValue,
                        code: code,
                        password: newPassword,
                        token: token
                    )
                }
                isSubmitting = false
                withAnimation(.easeOut(duration: 0.2)) {
                    showsSuccessToast = true
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                // 改密成功后清登录态，要求用新密码重新登录
                authSession.logout()
            } catch {
                guard !Task.isCancelled else { return }
                isSubmitting = false
                alertMessage = error.localizedDescription
            }
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 60
        countdownTask = Task {
            for remaining in stride(from: 59, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                countdown = remaining
            }
        }
    }

    private static func isValidEmail(_ value: String) -> Bool {
        let pattern = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}

#Preview {
    CompatibleNavigationStack {
        ChangePasswordView()
            .environmentObject(AuthSession())
    }
}
