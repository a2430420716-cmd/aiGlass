import AuthenticationServices
import SwiftUI

struct LoginView: View {
    var onSelectServer: (() -> Void)? = nil
    private enum LoginMode {
        case sms
        case password
    }

    private enum Field: Hashable {
        case phone
        case verificationCode
        case password
    }

    @EnvironmentObject private var authSession: AuthSession
    @FocusState private var focusedField: Field?

    @State private var loginMode: LoginMode = .password
    @State private var phoneNumber = ""
    @State private var verificationCode = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var agreedToTerms = false

    @State private var countdown = 0
    @State private var isSendingCode = false
    @State private var isLoggingIn = false
    @State private var alertMessage: String?
    @State private var countdownTask: Task<Void, Never>?
    @State private var showsForgotPassword = false
    @State private var showsAgreementDialog = false
    @State private var showsServiceAgreement = false
    @State private var showsPrivacyAgreement = false
    @State private var isWeChatLoggingIn = false
    @State private var isAppleLoggingIn = false
    @State private var showsWeChatBind = false
    @State private var weChatBindPayload: WeChatBindPayload?

    /// 对齐 Android：中国 IP 用手机号，海外用邮箱；默认手机号。
    @State private var isChinaIP = true
    @State private var accountModeResolved = false

    private static let agreementServiceURL = URL(string: "aiglass-agreement://service")!
    private static let agreementPrivacyURL = URL(string: "aiglass-agreement://privacy")!

    private var isEmailAccount: Bool { !isChinaIP }

    private var passwordRecoveryUsesEmail: Bool {
        let account = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if AuthAccountIdentifier.isEmail(account) { return true }
        if AuthAccountIdentifier.isPhone(account) { return false }
        return isEmailAccount
    }

    private var accountPlaceholder: String {
        if loginMode == .password {
            return L10n.t("请输入账号/手机号/邮箱", "Enter username, phone number or email")
        }
        return isChinaIP ? L10n.t("请输入手机号", "Phone number") : L10n.t("请输入邮箱", "Email")
    }

    private var accountErrorText: String {
        if loginMode == .password {
            return L10n.t("请输入有效账号，不能包含空格", "Enter a valid account without spaces")
        }
        return isChinaIP ? L10n.t("请输入正确的手机号", "Enter a valid phone number") : L10n.t("请输入正确的邮箱", "Please enter a valid email")
    }

    private var isAccountValid: Bool {
        if loginMode == .password {
            let account = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            return !account.isEmpty && !account.contains(where: { $0.isWhitespace })
        }
        return isContactAccountValid
    }

    private var isContactAccountValid: Bool {
        let account = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if isChinaIP {
            return account.count == 11 && account.allSatisfy(\.isNumber)
        }
        return Self.isValidEmail(account)
    }

    private var canSendCode: Bool {
        loginMode == .sms && isAccountValid && countdown == 0 && !isSendingCode && accountModeResolved
    }

    /// 账号 + 验证码/密码已填，可点登录（未勾选协议时点按钮弹同意框）
    private var isFormReady: Bool {
        guard accountModeResolved, isAccountValid, !isLoggingIn else { return false }

        switch loginMode {
        case .sms:
            return !verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .password:
            return !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var placeholderColor: Color {
        Color(red: 0.45, green: 0.45, blue: 0.45)
    }

    var body: some View {
        CompatibleNavigationStack {
            loginContent
                .compatibleNavigationDestination(isPresented: $showsForgotPassword) {
                    ForgotPasswordView(
                        initialAccount: phoneNumber,
                        isEmailAccount: passwordRecoveryUsesEmail
                    )
                }
                .compatibleNavigationDestination(isPresented: $showsServiceAgreement) {
                    AgreementDetailView(type: .service)
                }
                .compatibleNavigationDestination(isPresented: $showsPrivacyAgreement) {
                    AgreementDetailView(type: .privacy)
                }
                .compatibleNavigationDestination(isPresented: $showsWeChatBind) {
                    if let payload = weChatBindPayload {
                        WeChatBindView(
                            openid: payload.openid,
                            nickname: payload.nickname,
                            headimg: payload.headimg,
                            sex: payload.sex
                        )
                        .environmentObject(authSession)
                    }
                }
        }
    }

    private var loginContent: some View {
        ZStack(alignment: .top) {
            backgroundLayers

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    dismissKeyboard()
                }

            VStack(spacing: 0) {
                Spacer()

                inputFields

                agreementRow
                    .padding(.top, 16)

                loginButton
                    .padding(.top, 24)

                thirdPartySection
                    .padding(.top, 40)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .navigationBarHidden(true)
        .overlay(alignment: .topLeading) {
            if let onSelectServer {
                Button {
                    dismissKeyboard()
                    onSelectServer()
                } label: {
                    Label(L10n.t("选择服务器", "Select Server"), systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .padding(16)
                }
                .foregroundStyle(AppTheme.primaryText)
            }
        }
        .dismissKeyboardOnVerticalDrag(perform: dismissKeyboard)
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .alert(L10n.t("用户协议及隐私政策", "Terms of Service & Privacy Policy"), isPresented: $showsAgreementDialog) {
            Button(L10n.t("不同意", "Disagree"), role: .cancel) {}
            Button(L10n.t("同意并继续", "Agree and continue")) {
                agreedToTerms = true
                performLogin()
            }
        } message: {
            Text(L10n.t(
                "点击“同意并继续”，即表示您已阅读并理解《用户协议》和《隐私政策》。为更好地保护您的权益并遵守适用法律，协议说明了我们如何收集、存储、保护和使用您的信息。",
                "By tapping \"Agree and Continue\", you confirm that you have read and understood the Terms of Service and Privacy Policy. To better protect your rights and comply with applicable laws, the agreement explains how we collect, store, protect, and use your information."
            ))
        }
        .environment(\.openURL, OpenURLAction { url in
            handleAgreementURL(url)
        })
        .task {
            await resolveAccountMode()
        }
        .onDisappear {
            countdownTask?.cancel()
        }
    }

    private var backgroundLayers: some View {
        ZStack(alignment: .top) {
            Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF5 / 255)
                .ignoresSafeArea()

            Image("bg")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            Image("glass_bg")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding(.top, 137)
        }
    }

    private var inputFields: some View {
        VStack(spacing: 16) {
            TextField(
                "",
                text: $phoneNumber,
                prompt: Text(accountPlaceholder)
                    .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                    .foregroundColor(placeholderColor)
            )
            // IP 检测异步切换手机号/邮箱时，重建底层 UITextField，避免沿用旧数字键盘。
            .id(loginMode == .password ? "password-account-field" : (isChinaIP ? "phone-account-field" : "email-account-field"))
            .keyboardType(loginMode == .password ? .asciiCapable : (isChinaIP ? .numberPad : .emailAddress))
            .textContentType(loginMode == .password ? .username : (isChinaIP ? .telephoneNumber : .emailAddress))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(AppTheme.notoSansSC(size: 16, weight: .regular))
            .foregroundStyle(AppTheme.primaryText)
            .focused($focusedField, equals: .phone)
            .padding(.horizontal, 20)
            .frame(height: 56)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onChangeCompat(of: phoneNumber) { newValue in
                guard loginMode == .sms else { return }
                if isChinaIP {
                    let filtered = newValue.filter(\.isNumber)
                    if filtered.count > 11 {
                        phoneNumber = String(filtered.prefix(11))
                    } else if filtered != newValue {
                        phoneNumber = filtered
                    }
                } else {
                    let trimmed = newValue.replacingOccurrences(of: " ", with: "")
                    if trimmed != newValue {
                        phoneNumber = trimmed
                    }
                }
            }

            if loginMode == .sms {
                verificationCodeField
            } else {
                passwordField
                passwordModeActions
            }
        }
    }

    private var verificationCodeField: some View {
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
            .focused($focusedField, equals: .verificationCode)
            .onChangeCompat(of: verificationCode) { newValue in
                let filtered = newValue.filter(\.isNumber)
                if filtered.count > 6 {
                    verificationCode = String(filtered.prefix(6))
                } else if filtered != newValue {
                    verificationCode = filtered
                }
            }

            Button {
                sendVerificationCode()
            } label: {
                if isSendingCode {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 88)
                } else if countdown > 0 {
                    Text(L10n.t("\(countdown)s后重发", "Resend in \(countdown)s"))
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

    private var passwordField: some View {
        HStack(spacing: 12) {
            Group {
                if showsPassword {
                    TextField(
                        "",
                        text: $password,
                        prompt: Text(L10n.t("请输入密码", "Password"))
                            .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                            .foregroundColor(placeholderColor)
                    )
                } else {
                    SecureField(
                        "",
                        text: $password,
                        prompt: Text(L10n.t("请输入密码", "Password"))
                            .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                            .foregroundColor(placeholderColor)
                    )
                }
            }
            .textContentType(.password)
            .font(AppTheme.notoSansSC(size: 16, weight: .regular))
            .foregroundStyle(AppTheme.primaryText)
            .focused($focusedField, equals: .password)

            Button {
                showsPassword.toggle()
            } label: {
                Image(systemName: showsPassword ? "eye" : "eye.slash")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText.opacity(0.75))
                    .frame(width: 28, height: 44)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var passwordModeActions: some View {
        HStack {
            Button {
                switchToSMSLogin()
            } label: {
                Text(L10n.t("验证码登陆", "Code log in"))
                    .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                openForgotPassword()
            } label: {
                Text(L10n.t("忘记密码?", "forget password?"))
                    .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var agreementRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loginMode == .sms {
                Button {
                    switchToPasswordLogin()
                } label: {
                    Text(L10n.t("密码登陆", "Password log in"))
                        .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 10) {
                Button {
                    dismissKeyboard()
                    agreedToTerms.toggle()
                } label: {
                    Image(systemName: agreedToTerms ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(agreedToTerms ? AppTheme.accent : AppTheme.secondaryText)
                        .frame(width: 28, height: 28)
                        .padding(.top, 1)
                }
                .buttonStyle(.plain)

                Text(agreementAttributedText)
                    .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // simultaneous：点文案等同点单选框（可反选），《用户协议》《隐私政策》链接照常可点。
                    .simultaneousGesture(TapGesture().onEnded {
                        dismissKeyboard()
                        agreedToTerms.toggle()
                    })
            }
        }
    }

    private var agreementAttributedText: AttributedString {
        var text = AttributedString(L10n.t(
            "我已阅读并同意《用户协议》和《隐私政策》，首次登录会自动注册账号",
            "I have read and agree to the Terms of Service and Privacy Policy. First login will automatically create an account."
        ))
        text.foregroundColor = AppTheme.secondaryText

        if let range = text.range(of: L10n.t("《用户协议》", "Terms of Service")) {
            text[range].foregroundColor = AppTheme.primaryText
            text[range].link = Self.agreementServiceURL
            text[range].underlineStyle = nil
        }
        if let range = text.range(of: L10n.t("《隐私政策》", "Privacy Policy")) {
            text[range].foregroundColor = AppTheme.primaryText
            text[range].link = Self.agreementPrivacyURL
            text[range].underlineStyle = nil
        }
        return text
    }

    private func handleAgreementURL(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "aiglass-agreement" else {
            return .systemAction
        }
        dismissKeyboard()
        // 对齐 Android：点协议链接时自动勾选。
        // 异步派发，确保晚于文案上的 toggle 手势执行，避免链接点击后被反选。
        DispatchQueue.main.async {
            agreedToTerms = true
        }
        switch url.host {
        case "service":
            showsServiceAgreement = true
        case "privacy":
            showsPrivacyAgreement = true
        default:
            break
        }
        return .handled
    }

    private var loginButton: some View {
        Button {
            login()
        } label: {
            ZStack {
                Text(L10n.t("登陆", "Log in"))
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .opacity(isLoggingIn ? 0 : 1)

                if isLoggingIn {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(isFormReady ? Color(red: 0.20, green: 0.20, blue: 0.20) : Color(red: 0.70, green: 0.70, blue: 0.70))
            .clipShape(Capsule())
        }
        .disabled(!isFormReady)
    }

    private var thirdPartySection: some View {
        // 第三方登录入口跟随 App 语言，与服务器及账号输入类型无关。
        VStack(spacing: 20) {
            Text(L10n.t("使用第三方账号登录", "Log in with Linked accounts"))
                .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)

            if L10n.usesEnglish {
                appleLoginButton
            } else {
                Button {
                    wechatLogin()
                } label: {
                    ZStack {
                        Image("android_wechat")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                            .opacity(isWeChatLoggingIn ? 0.3 : 1)

                        if isWeChatLoggingIn {
                            ProgressView()
                        }
                    }
                }
                .disabled(isWeChatLoggingIn)
            }
        }
    }

    private var appleLoginButton: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.email]
            isAppleLoggingIn = true
        } onCompletion: { result in
            handleAppleAuthorization(result)
        }
        .signInWithAppleButtonStyle(.black)
        .environment(\.locale, Locale(identifier: L10n.usesEnglish ? "en" : "zh-Hans"))
        .frame(width: 220, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(isAppleLoggingIn)
        .overlay {
            if isAppleLoggingIn {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black)
                    .overlay {
                        ProgressView()
                            .tint(.white)
                    }
            } else if !agreedToTerms {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        alertMessage = L10n.t(
                            "请先阅读并同意《用户协议》和《隐私政策》",
                            "Please read and agree to the Terms of Service and Privacy Policy"
                        )
                    }
            }
        }
    }

    // MARK: - Actions

    private func dismissKeyboard() {
        focusedField = nil
    }

    private func resolveAccountMode() async {
        do {
            let china = try await AuthService.fetchIsChinaIP()
            await MainActor.run {
                applyAccountMode(isChinaIP: china)
            }
            print("[Login] account mode resolved, mode=\(china ? "phone" : "email")")
        } catch {
            await MainActor.run {
                applyAccountMode(isChinaIP: true)
            }
            print("[Login] resolve china ip failed, fallback phone login: \(error.localizedDescription)")
        }
    }

    private func applyAccountMode(isChinaIP: Bool) {
        let previousIsChinaIP = self.isChinaIP
        self.isChinaIP = isChinaIP
        accountModeResolved = true
        // 切换输入类型时清掉不兼容内容，避免手机号残留在邮箱框。
        if previousIsChinaIP != isChinaIP {
            phoneNumber = ""
            verificationCode = ""
            password = ""
            countdownTask?.cancel()
            countdown = 0
            isSendingCode = false
        }
    }

    private func openForgotPassword() {
        // Account entry and validation belong to recovery, which works before login.
        dismissKeyboard()
        showsForgotPassword = true
    }

    private func switchToPasswordLogin() {
        dismissKeyboard()
        loginMode = .password
        verificationCode = ""
        countdownTask?.cancel()
        countdown = 0
        isSendingCode = false
    }

    private func switchToSMSLogin() {
        dismissKeyboard()
        loginMode = .sms
        password = ""
        showsPassword = false
    }

    private func sendVerificationCode() {
        guard accountModeResolved else {
            alertMessage = L10n.t("正在检测登录方式，请稍候", "Checking login method, please wait")
            return
        }
        guard canSendCode else {
            if !isAccountValid {
                alertMessage = accountErrorText
            }
            return
        }

        dismissKeyboard()

        let account = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        isSendingCode = true

        Task {
            do {
                if isChinaIP {
                    try await AuthService.sendSMS(phoneNumber: account, type: .login)
                } else {
                    try await AuthService.sendEmailCode(email: account)
                }
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

    private func login() {
        guard accountModeResolved else {
            alertMessage = L10n.t("正在检测登录方式，请稍候", "Checking login method, please wait")
            return
        }

        guard isFormReady else {
            if !isAccountValid {
                alertMessage = accountErrorText
            } else if loginMode == .sms {
                alertMessage = L10n.t("请输入验证码", "Enter the verification code")
            } else {
                alertMessage = L10n.t("请输入密码", "Please enter password!")
            }
            return
        }

        guard agreedToTerms else {
            dismissKeyboard()
            showsAgreementDialog = true
            return
        }

        performLogin()
    }

    private func performLogin() {
        dismissKeyboard()

        let account = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoggingIn = true

        Task {
            do {
                let result: LoginResult?
                switch loginMode {
                case .sms:
                    let code = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !code.isEmpty else {
                        await MainActor.run {
                            isLoggingIn = false
                            alertMessage = L10n.t("请输入验证码", "Enter the verification code")
                        }
                        return
                    }
                    if isChinaIP {
                        result = try await AuthService.login(phoneNumber: account, code: code)
                    } else {
                        result = try await AuthService.loginByEmailCode(email: account, code: code)
                    }
                case .password:
                    let pwd = password.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !pwd.isEmpty else {
                        await MainActor.run {
                            isLoggingIn = false
                            alertMessage = L10n.t("请输入密码", "Please enter password!")
                        }
                        return
                    }
                    if isChinaIP {
                        result = try await AuthService.loginByPassword(phoneNumber: account, password: pwd)
                    } else {
                        result = try await AuthService.loginByEmailPassword(email: account, password: pwd)
                    }
                }

                await MainActor.run {
                    isLoggingIn = false
                    authSession.applyLogin(phoneNumber: account, result: result)
                }
            } catch {
                await MainActor.run {
                    isLoggingIn = false
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func wechatLogin() {
        guard !isWeChatLoggingIn else { return }
        guard agreedToTerms else {
            dismissKeyboard()
            alertMessage = L10n.t(
                "请先阅读并同意《用户协议》和《隐私政策》",
                "Please read and agree to the Terms of Service and Privacy Policy"
            )
            return
        }
        guard WeChatAuthManager.isSDKAvailable else {
            alertMessage = L10n.t(
                "微信 SDK 未集成，请用 AIGlass.xcworkspace 重新编译安装",
                "WeChat SDK not linked. Rebuild with AIGlass.xcworkspace"
            )
            return
        }
        guard WeChatAuthManager.shared.isWeChatInstalled else {
            alertMessage = L10n.t("请先安装微信客户端", "Please install WeChat first")
            return
        }

        dismissKeyboard()
        isWeChatLoggingIn = true
        WeChatAuthManager.shared.sendAuth { result in
            switch result {
            case .success(let code):
                loginByWechatCode(code)
            case .failure(let error):
                isWeChatLoggingIn = false
                if case .cancelled = error { return }
                alertMessage = error.localizedDescription
            }
        }
    }

    private func loginByWechatCode(_ code: String) {
        guard !code.isEmpty else {
            isWeChatLoggingIn = false
            alertMessage = L10n.t("微信授权失败", "WeChat authorization failed")
            return
        }
        Task {
            do {
                let result = try await AuthService.getWxUserInfo(code: code)
                await MainActor.run {
                    isWeChatLoggingIn = false
                    guard let result else {
                        alertMessage = L10n.t("微信登录失败", "WeChat login failed")
                        return
                    }
                    if let token = result.resolvedToken {
                        authSession.applyLogin(phoneNumber: "", token: token)
                        return
                    }
                    let openid = result.openid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !openid.isEmpty else {
                        alertMessage = L10n.t("微信登录信息缺失，请重试", "WeChat sign-in info missing. Try again")
                        return
                    }
                    weChatBindPayload = WeChatBindPayload(
                        openid: openid,
                        nickname: result.nickname ?? "",
                        headimg: result.headimg ?? "",
                        sex: result.sex ?? 0
                    )
                    showsWeChatBind = true
                }
            } catch {
                await MainActor.run {
                    isWeChatLoggingIn = false
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleAppleAuthorization(_ authorizationResult: Result<ASAuthorization, Error>) {
        switch authorizationResult {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  !identityToken.isEmpty else {
                isAppleLoggingIn = false
                alertMessage = L10n.t("苹果授权信息缺失，请重试", "Apple authorization data is missing. Try again")
                return
            }
            loginByApple(identityToken: identityToken)

        case .failure(let error):
            isAppleLoggingIn = false
            let nsError = error as NSError
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue {
                return
            }
            alertMessage = L10n.t("Apple 授权失败，请重试", "Apple authorization failed. Try again.")
        }
    }

    private func loginByApple(identityToken: String) {
        Task {
            do {
                let result = try await AuthService.loginByApple(identityToken: identityToken)
                await MainActor.run {
                    isAppleLoggingIn = false
                    authSession.applyLogin(phoneNumber: "", result: result)
                }
            } catch {
                await MainActor.run {
                    isAppleLoggingIn = false
                    if let apiError = error as? APIError, case .network = apiError {
                        alertMessage = apiError.localizedDescription
                    } else {
                        // 原始服务端错误保留在 HTTP 日志，界面不直接显示后台语言或内部异常。
                        alertMessage = L10n.t(
                            "Apple 登录失败，请稍后重试",
                            "Apple sign-in failed. Try again later."
                        )
                    }
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

    private static func isValidEmail(_ value: String) -> Bool {
        let pattern = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}

struct WeChatBindPayload: Identifiable {
    let id = UUID()
    let openid: String
    let nickname: String
    let headimg: String
    let sex: Int
}

#Preview {
    LoginView()
        .environmentObject(AuthSession())
}
