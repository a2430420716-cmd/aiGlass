import SwiftUI

struct BluetoothFirmwareUpdateDialog: View {
    let prompt: DeviceFirmwareUpdateCoordinator.UpdateOffer
    /// 未传标题时按当前 App 语言实时生成，避免中文默认值在切换英文后残留。
    var title: String? = nil
    var showsUpgradeButton: Bool = true
    let onCancel: () -> Void
    let onUpgrade: () -> Void
    @State private var packageSizeText: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    if canDismiss { onCancel() }
                }

            VStack(alignment: .leading, spacing: 0) {
                Text(title ?? L10n.t("蓝牙固件升级", "Bluetooth Firmware Update"))
                    .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)

                Text(versionLine)
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                Text(L10n.t("欢迎使用MOCO AI Glasses，为了提升体验，我们推荐升级至此版本。", "Welcome to MOCO AI Glasses. To improve your experience, we recommend updating to this version."))
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineSpacing(4)
                    .padding(.top, 16)

                ScrollView(showsIndicators: false) {
                    Text(releaseNotes)
                        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(.top, 12)

                actionButtons
                    .padding(.top, 24)
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 520)
            .background(AppTheme.cardBackground)
            .contentShape(Rectangle())
            .onTapGesture {}
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
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
                        .frame(height: 50)
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
                        .frame(height: 50)
                        .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var canDismiss: Bool { !showsUpgradeButton || !prompt.serverInfo.isForced }

    private var releaseNotes: String {
        let text = HTMLPlainText.from(prompt.serverInfo.content).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? L10n.t("优化使用体验，修复已知问题。", "Improved experience and bug fixes.") : text
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
