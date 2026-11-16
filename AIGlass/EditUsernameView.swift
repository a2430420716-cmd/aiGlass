import SwiftUI

enum UsernameValidator {
    @MainActor
    static var hint: String {
        L10n.t(
            "2-20位字符，支持中英文、数字、下划线，空格，不包含特殊字符",
            "2-20 characters, supports Chinese and English, numbers, underscores, spaces, does not contain special characters"
        )
    }
    private static let pattern = #"^[\u4e00-\u9fa5a-zA-Z0-9_ ]{2,20}$"#

    @MainActor
    static func validationMessage(for nickname: String) -> String? {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return L10n.t("用户名不能为空", "Username cannot be empty")
        }
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            return hint
        }
        return nil
    }
}

struct EditUsernameView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession

    @State private var nicknameDraft: String
    @State private var isSaving = false
    @State private var alertMessage: String?
    @FocusState private var isNicknameFocused: Bool

    init(initialNickname: String) {
        _nicknameDraft = State(initialValue: initialNickname)
    }

    private var trimmedNickname: String {
        nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentNickname: String {
        authSession.userInfo?.nickname.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var canConfirm: Bool {
        !isSaving && UsernameValidator.validationMessage(for: nicknameDraft) == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            VStack(alignment: .leading, spacing: 12) {
                nicknameField

                Text(UsernameValidator.hint)
                    .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer(minLength: 0)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .overlay {
            if isSaving {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView {
                        Text(L10n.t("保存中...", "Saving..."))
                            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                    .tint(AppTheme.primaryText)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(AppTheme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
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
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isNicknameFocused = true
            }
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("修改用户名", "Modify username"))
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

                Button(L10n.t("确定", "OK")) {
                    saveNickname()
                }
                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                .foregroundStyle(canConfirm ? AppTheme.primaryText : AppTheme.secondaryText)
                .disabled(!canConfirm)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var nicknameField: some View {
        HStack(spacing: 12) {
            TextField("", text: $nicknameDraft)
                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .focused($isNicknameFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit {
                    if canConfirm {
                        saveNickname()
                    }
                }

            if !nicknameDraft.isEmpty {
                Button {
                    nicknameDraft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color(red: 0.72, green: 0.72, blue: 0.72))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func saveNickname() {
        if let message = UsernameValidator.validationMessage(for: nicknameDraft) {
            alertMessage = message
            return
        }

        guard trimmedNickname != currentNickname else {
            dismiss()
            return
        }

        guard !isSaving else { return }

        let headimg = authSession.userInfo?.headimg ?? ""
        isSaving = true
        Task {
            do {
                try await authSession.saveUserProfile(nickname: trimmedNickname, headimg: headimg)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                alertMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    CompatibleNavigationStack {
        EditUsernameView(initialNickname: "MOCO_78123")
            .environmentObject(AuthSession())
    }
}
