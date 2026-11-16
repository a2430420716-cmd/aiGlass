import SwiftUI

struct AppUpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession

    private var appInfo: AppVersionInfo? {
        authSession.userInfo?.appInfo
    }

    private var updateItems: [String] {
        guard let content = appInfo?.content else { return [] }
        return HTMLPlainText.from(content)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    currentVersionCard
                    upgradeIcon
                    latestVersionText
                    updateContentSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .safeAreaInset(edge: .bottom) {
            updateButton
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .background(AppTheme.background)
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("APP更新", "APP update"))
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

    private var currentVersionCard: some View {
        HStack {
            Text(L10n.t("当前APP版本", "Current APP version"))
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)

            Spacer()

            Text(AppBundleInfo.displayVersion)
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var upgradeIcon: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.36, green: 0.78, blue: 0.44))
                .frame(width: 120, height: 120)

            Image(systemName: "arrow.up.doc.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var latestVersionText: some View {
        Text(AppBundleInfo.displayVersion(appInfo?.version ?? ""))
            .font(AppTheme.notoSansSC(size: 18, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .frame(maxWidth: .infinity)
    }

    private var updateContentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("更新内容：", "Release notes:"))
                .font(AppTheme.notoSansSC(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)

            if updateItems.isEmpty {
                Text(L10n.t("暂无更新说明", "No release notes yet"))
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(updateItems.enumerated()), id: \.offset) { index, item in
                        Text(formattedUpdateItem(index: index + 1, text: item))
                            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var updateButton: some View {
        Button {
            AppBundleInfo.openAppStore(preferredURL: appInfo?.downloadURL)
        } label: {
            Text(L10n.t("立即更新", "Update now"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func formattedUpdateItem(index: Int, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^\d+[\.,、]"#, options: .regularExpression) != nil {
            return trimmed
        }
        return "\(index). \(trimmed)"
    }
}

#Preview {
    CompatibleNavigationStack {
        AppUpdateView()
            .environmentObject(AuthSession())
    }
}
