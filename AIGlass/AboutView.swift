import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession
    @ObservedObject private var languageManager = AppLanguageManager.shared
    @State private var showsLatestVersionToast = false
    @State private var selectedLanguage = AppSettings.language
    @State private var selectedDataStorage = AppSettings.dataStorageRegion

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                    appInfoSection
                        .padding(.top, 24)
                        .padding(.bottom, 32)

                    VStack(spacing: 12) {
                        NavigationLink {
                            LanguageSettingsView()
                        } label: {
                            AboutMenuRowContent(
                                title: L10n.t("语言设置", "Language"),
                                value: selectedLanguage.aboutDisplayName,
                                showsChevron: true
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .background(AppTheme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            DataStorageSettingsView()
                        } label: {
                            AboutMenuRowContent(
                                title: L10n.t("数据存储", "Data Storage"),
                                value: selectedDataStorage.title,
                                showsChevron: true
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .background(AppTheme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)

                        appUpdateRow
                    }

                    Spacer(minLength: 48)

                    footerSection
                        .padding(.top, 32)
                        .padding(.bottom, 32)
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .onAppear {
            selectedLanguage = AppSettings.language
            selectedDataStorage = AppSettings.dataStorageRegion
        }
        .overlay(alignment: .bottom) {
            if showsLatestVersionToast {
                Text(L10n.t("当前已是最新版本", "You're on the latest version"))
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
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("关于", "About"))
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

    private var appInfoSection: some View {
        VStack(spacing: 12) {
            Image("logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text("MOCO AI")
                .font(AppTheme.notoSansSC(size: 20, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)

            Text(L10n.t("版本号：", "Version ") + AppBundleInfo.aboutDisplayVersion)
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var appUpdateRow: some View {
        if authSession.hasAppUpdateAvailable {
            NavigationLink {
                AppUpdateView()
            } label: {
                AboutMenuRowContent(
                    title: L10n.t("检测应用更新", "Check for Updates"),
                    showsUpdateBadge: true,
                    showsChevron: true
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .background(AppTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                showLatestVersionToast()
            } label: {
                AboutMenuRowContent(
                    title: L10n.t("检测应用更新", "Check for Updates"),
                    showsUpdateBadge: false,
                    showsChevron: true
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .background(AppTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
    }

    private func showLatestVersionToast() {
        withAnimation(.easeOut(duration: 0.2)) {
            showsLatestVersionToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeOut(duration: 0.2)) {
                showsLatestVersionToast = false
            }
        }
    }

    private var footerSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                NavigationLink {
                    AgreementDetailView(type: .service)
                } label: {
                    Text(L10n.t("用户协议", "User Agreement"))
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                }
                .buttonStyle(.plain)

                Text("|")
                    .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)

                NavigationLink {
                    AgreementDetailView(type: .privacy)
                } label: {
                    Text(L10n.t("隐私政策", "Privacy Policy"))
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                }
                .buttonStyle(.plain)
            }

            Text(L10n.t("App备案号 沪ICP备2021009247号-4A", "ICP Filing No. 沪ICP备2021009247号-4A"))
                .font(AppTheme.notoSansSC(size: 11, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AboutMenuRowContent: View {
    let title: String
    var value: String?
    var showsUpdateBadge = false
    var showsChevron = true

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)

                if showsUpdateBadge {
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 8, height: 8)
                }
            }

            Spacer()

            if let value {
                Text(value)
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
    }
}

#Preview {
    CompatibleNavigationStack {
        AboutView()
            .environmentObject(AuthSession())
    }
}
