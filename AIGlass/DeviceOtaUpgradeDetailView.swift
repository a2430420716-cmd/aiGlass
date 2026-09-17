import SwiftUI

struct DeviceOtaUpgradeDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var updateCoordinator: DeviceFirmwareUpdateCoordinator
    @EnvironmentObject private var otaManager: BluetoothOtaUpgradeManager
    @EnvironmentObject private var importManager: MediaImportManager
    @EnvironmentObject private var authSession: AuthSession

    let kind: OtaUpgradeKind
    let offer: DeviceFirmwareUpdateCoordinator.UpdateOffer

    @ObservedObject private var ble: AstraA1BleManager

    @State private var fileSizeText: String?
    @State private var batteryAlertMessage: String?

    init(kind: OtaUpgradeKind, offer: DeviceFirmwareUpdateCoordinator.UpdateOffer, ble: AstraA1BleManager) {
        self.kind = kind
        self.offer = offer
        _ble = ObservedObject(wrappedValue: ble)
    }

    private var contentLines: [String] {
        HTMLPlainText.from(offer.serverInfo.content)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var isUpgradingForThisPage: Bool {
        otaManager.isUpgrading && isStateForCurrentOffer
    }

    private var isStateForCurrentOffer: Bool {
        otaManager.activeKind == kind &&
            otaManager.activeTargetVersion == offer.serverInfo.version
    }

    private var showsSuccess: Bool {
        if case .completed = otaManager.state, isStateForCurrentOffer {
            return true
        }
        return false
    }

    private var failureMessage: String? {
        if case .failed(let message) = otaManager.state,
           isStateForCurrentOffer {
            return message
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            if showsSuccess {
                resultView(
                    imageName: "ota_upgrade_success",
                    title: L10n.t("升级成功", "Update Successful"),
                    subtitle: L10n.t("快去体验新版本吧！", "Enjoy the new version!")
                )
            } else if let failureMessage {
                resultView(
                    imageName: "ota_upgrade_failure",
                    title: L10n.t("升级失败", "Update Failed"),
                    subtitle: failureMessage
                )
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        currentVersionCard
                        centerSection
                        contentSection
                        warningSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }

                if !isUpgradingForThisPage {
                    upgradeButton
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                }
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .onAppear {
            ble.ensureConnected(reason: "otaDetail")
            ble.refreshDeviceVersionsAndStorage()
            loadFileSizeIfNeeded()
        }
        .onChangeCompat(of: ble.isReady) { ready in
            if ready {
                ble.refreshDeviceVersionsAndStorage()
            }
        }
        .alert(L10n.t("无法升级", "Unable to Update"), isPresented: Binding(
            get: { batteryAlertMessage != nil },
            set: { if !$0 { batteryAlertMessage = nil } }
        )) {
            Button(L10n.t("知道了", "Got It"), role: .cancel) {}
        } message: {
            Text(batteryAlertMessage ?? "")
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(kind.pageTitle)
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button {
                    dismissPage()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                .disabled(isUpgradingForThisPage)

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var currentVersionCard: some View {
        HStack {
            Text(kind.currentVersionTitle)
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
            Spacer()
            Text(currentVersionDisplay)
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var centerSection: some View {
        VStack(spacing: 16) {
            if isUpgradingForThisPage, let progress = otaManager.state.overallProgress {
                OtaCircularProgressView(progress: progress)
            } else {
                Image("android_upgrade")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
            }

            Text(targetVersionLine)
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var targetVersionLine: String {
        let version = displayVersion(offer.serverInfo.version)
        if let fileSizeText {
            return "\(version) | \(fileSizeText)"
        }
        return version
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("\(kind.contentTitlePrefix)\(displayVersion(offer.serverInfo.version))更新内容：", "\(kind.contentTitlePrefix) \(displayVersion(offer.serverInfo.version)) What's New:"))
                .font(AppTheme.notoSansSC(size: 15, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            ForEach(Array(contentLines.enumerated()), id: \.offset) { index, line in
                Text("\(index + 1). \(line)")
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var warningSection: some View {
        VStack(spacing: 12) {
            Text(attributedBatteryWarning)
                .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
                Text(L10n.t("更新过程中眼镜系统功能不可使用", "Glasses features are unavailable during the update"))
                    .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
    }

    private var attributedBatteryWarning: AttributedString {
        let prefix = kind == .firmware
            ? L10n.t("OTA升级需要眼镜保持 Wi-Fi 连接和", "OTA update requires Wi-Fi and ")
            : L10n.t("OTA升级需要", "OTA update requires ")
        var text = AttributedString(prefix)
        var highlight = AttributedString(L10n.t("眼镜电量>15%", "glasses battery >15%"))
        highlight.foregroundColor = .red
        text.append(highlight)
        return text
    }

    private var upgradeButton: some View {
        Button(action: startUpgrade) {
            Text(L10n.t("立即升级", "Update Now"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func resultView(imageName: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)

            Text(title)
                .font(AppTheme.notoSansSC(size: 20, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            Text(subtitle)
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startUpgrade() {
        guard !otaManager.isUpgrading else { return }
        guard let battery = ble.deviceBatteryPercent else {
            batteryAlertMessage = L10n.t("正在读取眼镜电量，请稍后再试。", "Reading glasses battery. Please try again later.")
            return
        }
        let lowBatteryThreshold = 15
        guard battery > lowBatteryThreshold else {
            batteryAlertMessage = L10n.t("眼镜电量不足（当前\(battery)%），请充电至 15% 以上再升级。", "Battery too low (\(battery)%). Charge to above 15% before updating.")
            return
        }

        switch kind {
        case .bluetooth:
            updateCoordinator.beginBluetoothUpgrade(
                serverInfo: offer.serverInfo,
                authorization: authSession.token,
                ble: ble,
                otaManager: otaManager,
                importManager: importManager
            )
        case .firmware:
            updateCoordinator.beginFirmwareUpgrade(
                serverInfo: offer.serverInfo,
                authorization: authSession.token,
                ble: ble,
                otaManager: otaManager,
                importManager: importManager
            )
        }
    }

    private func dismissPage() {
        if otaManager.state.isTerminal, isStateForCurrentOffer {
            otaManager.resetCompletedState()
        }
        dismiss()
    }

    private func loadFileSizeIfNeeded() {
        guard fileSizeText == nil,
              let url = URL(string: offer.serverInfo.downloadURL) else { return }
        Task {
            if let bytes = await FirmwareDownloadClient.fetchContentLength(url: url) {
                await MainActor.run {
                    fileSizeText = Self.formatFileSize(bytes)
                }
            }
        }
    }

    private var liveCurrentVersion: String? {
        switch kind {
        case .bluetooth:
            return ble.deviceVersion2800
        case .firmware:
            return ble.deviceVersion6350
        }
    }

    private var currentVersionDisplay: String {
        if ble.isQueryingDeviceVersionsAndStorage,
           liveCurrentVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return L10n.t("加载中...", "Loading...")
        }
        if let live = liveCurrentVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !live.isEmpty {
            return displayVersion(live)
        }
        return displayVersion(offer.currentVersion)
    }

    private func displayVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        if trimmed.hasPrefix("V") || trimmed.hasPrefix("v") { return trimmed }
        return "V\(trimmed)"
    }

    private static func formatFileSize(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 100 {
            return String(format: "%.0fM", mb)
        }
        if mb >= 10 {
            return String(format: "%.0fM", mb)
        }
        return String(format: "%.1fM", mb)
    }
}

private struct OtaCircularProgressView: View {
    let progress: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(red: 0.90, green: 0.90, blue: 0.90), lineWidth: 10)

            Circle()
                .trim(from: 0, to: CGFloat(progress) / 100)
                .stroke(
                    Color(red: 0.36, green: 0.78, blue: 0.44),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text("\(progress)%")
                .font(AppTheme.notoSansSC(size: 28, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
        }
        .frame(width: 140, height: 140)
    }
}
