import SwiftUI

struct ForgotPasswordView: View {
    private enum Field: Hashable {
        case phone
        case code
        case password
        case confirmation
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    let initialAccount: String
    let isEmailAccount: Bool

    @State private var account: String
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

    init(initialAccount: String = "", isEmailAccount: Bool = false) {
        self.initialAccount = initialAccount
        self.isEmailAccount = isEmailAccount
        _account = State(initialValue: initialAccount)
    }

    /// 兼容旧调用：仅传手机号。
    init(initialPhoneNumber: String = "") {
        self.init(initialAccount: initialPhoneNumber, isEmailAccount: false)
    }

    private var normalizedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var accountPlaceholder: String {
        isEmailAccount
            ? L10n.t("请输入邮箱", "Enter email")
            : L10n.t("请输入手机号", "Enter phone number")
    }

    private var accountErrorText: String {
        isEmailAccount
            ? L10n.t("请输入正确的邮箱", "Enter a valid email")
            : L10n.t("请输入正确的手机号", "Enter a valid phone number")
    }

    private var subtitleText: String {
        if isEmailAccount {
            return L10n.t(
                "未注册的邮箱验证成功后将自动注册并绑定",
                "Unregistered emails will be registered and linked after verification"
            )
        }
        return L10n.t(
            "未注册的手机号验证成功后将自动注册并绑定",
            "Unregistered phone numbers will be registered and linked after verification"
        )
    }

    private var isAccountValid: Bool {
        if isEmailAccount {
            return Self.isValidEmail(normalizedAccount)
        }
        return normalizedAccount.count == 11 && normalizedAccount.allSatisfy(\.isNumber)
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

    private var canSendCode: Bool {
        isAccountValid && countdown == 0 && !isSendingCode
    }

    private var canSubmit: Bool {
        isAccountValid
            && !normalizedVerificationCode.isEmpty
            && normalizedPassword.count >= 8
            && !normalizedPasswordConfirmation.isEmpty
            && normalizedPassword == normalizedPasswordConfirmation
            && !isSubmitting
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
                        subtitle
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 16)

                        formFields

                        passwordHint
                            .padding(.top, 14)
                            .padding(.horizontal, 24)

                        Spacer(minLength: 32)

                        submitButton
                            .padding(.horizontal, 16)
                            .padding(.bottom, 120)
                    }
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .compatibleScrollDismissesKeyboard()
                .simultaneousGesture(
                    TapGesture().onEnded {
                        focusedField = nil
                    }
                )
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
            Text(L10n.t("忘记密码", "Forgot Password"))
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

    private var subtitle: some View {
        Text(subtitleText)
            .font(AppTheme.notoSansSC(size: 12, weight: .regular))
            .foregroundStyle(AppTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
    }

    private var formFields: some View {
        VStack(spacing: 10) {
            TextField(
                "",
                text: $account,
                prompt: Text(accountPlaceholder)
                    .foregroundColor(AppTheme.secondaryText.opacity(0.55))
            )
            .keyboardType(isEmailAccount ? .emailAddress : .numberPad)
            .textContentType(isEmailAccount ? .emailAddress : .telephoneNumber)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(AppTheme.notoSansSC(size: 15, weight: .regular))
            .foregroundStyle(AppTheme.primaryText)
            .focused($focusedField, equals: .phone)
            .padding(.horizontal, 24)
            .frame(height: 52)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onChangeCompat(of: account) { newValue in
                if isEmailAccount {
                    let trimmed = newValue.replacingOccurrences(of: " ", with: "")
                    if trimmed != newValue {
                        account = trimmed
                    }
                } else {
                    let filtered = newValue.filter(\.isNumber)
                    account = String(filtered.prefix(11))
                }
            }

            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $verificationCode,
                    prompt: Text(L10n.t("请输入验证码", "Enter verification code"))
                        .foregroundColor(AppTheme.secondaryText.opacity(0.55))
                )
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
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
                             ? L10n.t("\(countdown)s后重发", "Resend in \(countdown)s")
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
                field: .password
            )

            passwordField(
                placeholder: L10n.t("再次确认新密码", "Confirm new password"),
                text: $passwordConfirmation,
                isVisible: $showsPasswordConfirmation,
                field: .confirmation
            )
        }
        .padding(.horizontal, 16)
    }

    private func passwordField(
        placeholder: String,
        text: Binding<String>,
        isVisible: Binding<Bool>,
        field: Field
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
            .textContentType(.newPassword)
            .font(AppTheme.notoSansSC(size: 15, weight: .regular))
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
                Image(systemName: isVisible.wrappedValue ? "eye" : "eye.slash")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText.opacity(0.75))
                    .frame(width: 28, height: 44)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var passwordHint: some View {
        Text(L10n.t(
            "请输入8-18位密码，支持英文、数字、符号，至少包含\n其中两种，不能包含空格",
            "Enter an 8–18 character password with letters, numbers, or symbols.\nInclude at least two types. No spaces."
        ))
            .font(AppTheme.notoSansSC(size: 12, weight: .regular))
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var submitButton: some View {
        Button {
            resetPassword()
        } label: {
            ZStack {
                Text(L10n.t("立即进入", "Continue"))
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
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
        guard canSendCode else {
            if !isAccountValid {
                alertMessage = accountErrorText
            }
            return
        }

        focusedField = nil
        isSendingCode = true

        Task {
            do {
                if isEmailAccount {
                    try await AuthService.sendModifyEmailCode(email: normalizedAccount)
                } else {
                    try await AuthService.sendSMS(
                        phoneNumber: normalizedAccount,
                        type: .forgotPassword
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

    private func resetPassword() {
        let accountValue = normalizedAccount
        let code = normalizedVerificationCode
        let newPassword = normalizedPassword
        let confirmPassword = normalizedPasswordConfirmation

        guard isAccountValid else {
            alertMessage = accountErrorText
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
                    try await AuthService.modifyEmailPassword(
                        email: accountValue,
                        code: code,
                        password: newPassword
                    )
                } else {
                    try await AuthService.forgetPassword(
                        phoneNumber: accountValue,
                        code: code,
                        password: newPassword
                    )
                }
                isSubmitting = false
                withAnimation(.easeOut(duration: 0.2)) {
                    showsSuccessToast = true
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                dismiss()
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
        ForgotPasswordView(initialAccount: "13812345678", isEmailAccount: false)
    }
}
