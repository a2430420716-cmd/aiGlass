import SwiftUI

struct BluetoothFirmwareUpdateDialog: View {
    let prompt: DeviceFirmwareUpdateCoordinator.UpdateOffer
    /// 未传标题时按当前 App 语言实时生成，避免中文默认值在切换英文后残留。
    var title: String? = nil
    var showsUpgradeButton: Bool = true
    let onCancel: () -> Void
    let onUpgrade: () -> Void
    @State private var packageSizeText: String?
    @State private var releaseNotesHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if canDismiss { onCancel() }
                    }

                VStack(alignment: .leading, spacing: 0) {
                    Text(title ?? L10n.t("眼镜蓝牙升级", "Glasses Bluetooth update"))
                        .font(AppTheme.notoSansSC(size: 17, weight: .bold))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)

                    Text(versionLine)
                        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)

                    Text(L10n.t("欢迎使用MOCO AI Glasses，为了提升体验，我们推荐升级至此版本", "Welcome to MOCO AI Glasses. To improve your experience, we recommend updating to this version."))
                        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)

                    ScrollView(showsIndicators: false) {
                        Text(releaseNotes)
                            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .background {
                                GeometryReader { content in
                                    Color.clear.preference(key: FirmwareUpdateNotesHeightKey.self, value: content.size.height)
                                }
                            }
                    }
                    .frame(height: min(max(20, releaseNotesHeight), min(180, geometry.size.height * 0.3)))
                    .onPreferenceChange(FirmwareUpdateNotesHeightKey.self) { releaseNotesHeight = $0 }
                    .padding(.top, 8)

                    actionButtons
                        .padding(.top, 16)
                        .padding(.bottom, 18)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 420)
                .background(AppTheme.cardBackground)
                .contentShape(Rectangle())
                .onTapGesture {}
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
        }
        .transition(.opacity)
        .task(id: prompt.serverInfo.downloadURL) {
            packageSizeText = nil
            guard let url = URL(string: prompt.serverInfo.downloadURL),
                  let bytes = await FirmwareDownloadClient.fetchContentLength(url: url),
                  !Task.isCancelled else { return }
            packageSizeText = String(format: "%.1fM", Double(bytes) / 1024 / 1024)
        }
    }

    private var versionLine: String {
        let version = displayVersion(prompt.serverInfo.version)
        guard let packageSizeText else { return version }
        return "\(version) | \(packageSizeText)"
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if canDismiss {
                Button(action: onCancel) {
                    Text(showsUpgradeButton ? L10n.t("取消", "Cancel") : L10n.t("知道了", "Got it"))
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(showsUpgradeButton ? AppTheme.primaryText : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(showsUpgradeButton ? Color(red: 0.92, green: 0.92, blue: 0.92) : Color(red: 0.20, green: 0.20, blue: 0.20))
                        .clipShape(Capsule())
                }
            }

            if showsUpgradeButton {
                Button(action: onUpgrade) {
                    Text(L10n.t("立即升级", "Update now"))
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var canDismiss: Bool { !showsUpgradeButton || !prompt.serverInfo.isForced }

    private var releaseNotes: String {
        let text = HTMLPlainText.from(prompt.serverInfo.localizedContent).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? L10n.t("暂无更新内容", "No release notes") : text
    }

    private func displayVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        if trimmed.hasPrefix("V") || trimmed.hasPrefix("v") {
            return trimmed
        }
        return "V\(trimmed)"
    }
}

private struct FirmwareUpdateNotesHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
