import SwiftUI

struct ProfileView: View {
    @Binding var showsTabBar: Bool
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var pairingCoordinator: PairingCoordinator
    @ObservedObject private var languageManager = AppLanguageManager.shared

    @State private var showLogoutConfirm = false
    @State private var tabBarSuppressionCount = 0

    private let menuItems: [ProfileMenuItem] = [
        ProfileMenuItem(title: "账号管理", assetIcon: "android_profile_account"),
        ProfileMenuItem(title: "问题反馈", assetIcon: "android_profile_feedback"),
        ProfileMenuItem(title: "关于", assetIcon: "android_profile_about")
    ]

    var body: some View {
        CompatibleNavigationStack {
            content
        }
        .environment(\.tabBarSuppressionCount, $tabBarSuppressionCount)
        .onChangeCompat(of: tabBarSuppressionCount) { _ in
            updateTabBarVisibility()
        }
        .alert(L10n.t("退出登录", "Log Out"), isPresented: $showLogoutConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("退出", "Log Out"), role: .destructive) {
                performLogout()
            }
        } message: {
            Text(L10n.t("确定要退出当前账号吗？", "Are you sure you want to log out?"))
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    profileHeader

                    VStack(spacing: 12) {
                        ForEach(menuItems) { item in
                            if item.title == "账号管理" {
                                NavigationLink {
                                    AccountManagementView(showsTabBar: $showsTabBar)
                                } label: {
                                    ProfileMenuRowContent(item: item)
                                }
                                .buttonStyle(.plain)
                            } else if item.title == "问题反馈" {
                                NavigationLink {
                                    FeedbackView(showsTabBar: $showsTabBar)
                                        .environmentObject(authSession)
                                } label: {
                                    ProfileMenuRowContent(item: item)
                                }
                                .buttonStyle(.plain)
                            } else if item.title == "关于" {
                                NavigationLink {
                                    AboutView()
                                        .environmentObject(authSession)
                                } label: {
                                    ProfileMenuRowContent(item: item)
                                }
                                .buttonStyle(.plain)
                            } else {
                                ProfileMenuRow(item: item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }

            logoutButton
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .task {
            await authSession.refreshUserInfo()
        }
    }

    private var displayNickname: String {
        let value = authSession.userInfo?.nickname.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? L10n.t("用户", "User") : value
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            ProfileAvatarView(
                imageURL: authSession.userInfo?.headimg,
                cacheToken: authSession.avatarCacheToken,
                previewImage: authSession.localAvatarImage
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(displayNickname)
                    .font(AppTheme.notoSansSC(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)

                Text(maskedPhone)
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 8)

            NavigationLink {
                PersonalInfoView()
                    .environmentObject(authSession)
            } label: {
                Text(L10n.t("编辑资料", "Edit Profile"))
                    .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppTheme.cardBackground)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color(red: 0.88, green: 0.88, blue: 0.88), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }

    private var maskedPhone: String {
        let phone = authSession.phoneNumber ?? ""
        guard phone.count == 11 else { return phone.isEmpty ? L10n.t("未绑定手机号", "No phone linked") : phone }
        let prefix = phone.prefix(3)
        let suffix = phone.suffix(4)
        return "\(prefix)****\(suffix)"
    }

    private var logoutButton: some View {
        Button {
            showLogoutConfirm = true
        } label: {
            Text(L10n.t("退出账号", "Log Out"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                .clipShape(Capsule())
        }
    }

    private func performLogout() {
        // 对齐 Android：普通退出只清登录态，BLE 与本地设备缓存继续保留。
        pairingCoordinator.resetForLogout(keepDeviceConnection: true)
        showsTabBar = true
        authSession.logout()
    }

    private func updateTabBarVisibility() {
        showsTabBar = tabBarSuppressionCount == 0
    }
}

private struct ProfileMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let assetIcon: String
}

private struct ProfileMenuRow: View {
    let item: ProfileMenuItem

    var body: some View {
        Button {} label: {
            ProfileMenuRowContent(item: item)
        }
        .buttonStyle(.plain)
    }
}

private struct ProfileMenuRowContent: View {
    let item: ProfileMenuItem

    @MainActor
    static func localizedTitle(_ title: String) -> String {
        switch title {
        case "账号管理": return L10n.t("账号管理", "Account")
        case "问题反馈": return L10n.t("问题反馈", "Feedback")
        case "关于": return L10n.t("关于", "About")
        default: return title
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(item.assetIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)

            Text(Self.localizedTitle(item.title))
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

#Preview {
    ProfileView(showsTabBar: .constant(true))
        .environmentObject(AuthSession())
        .environmentObject(PairingCoordinator())
}
