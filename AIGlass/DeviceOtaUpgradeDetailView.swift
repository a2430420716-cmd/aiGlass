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
    @State private var entryGeneration: DeviceGeneration
    @State private var gen1WifiSSID = ""
    @State private var gen1WifiPassword = ""
    @State private var hasEditedGen1WifiSSID = false
    @StateObject private var wifiSSIDReader = CurrentWifiSSIDReader()

    init(kind: OtaUpgradeKind, offer: DeviceFirmwareUpdateCoordinator.UpdateOffer, ble: AstraA1BleManager) {
        self.kind = kind
        self.offer = offer
        _ble = ObservedObject(wrappedValue: ble)
        _entryGeneration = State(initialValue: ble.deviceGeneration)
    }

    private var needsGen1Wifi: Bool {
        entryGeneration == .gen1G5K61 && kind == .firmware
    }

    private var isGen1BluetoothRecovery: Bool {
        kind == .bluetooth && entryGeneration == .gen1G5K61
            && offer.isGen1BluetoothRecovery
            && ble.deviceBluetoothIdentifier == offer.serialNumber
            && UUID(uuidString: offer.serialNumber).map {
                Gen1BluetoothOtaRecoveryStore().record(for: $0) != nil
            } == true
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

    private var isOfferDeviceAvailable: Bool {
        ble.isDeviceAvailable
            && ble.deviceGeneration == entryGeneration
            && ble.matchesCurrentDevice(serialNumber: offer.serialNumber, hardwareSN: offer.serialNumber)
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

    private var unconfirmedMessage: String? {
        if case .versionUnconfirmed(let message) = otaManager.state, isStateForCurrentOffer {
            return message
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            if showsSuccess {
                resultView(
                    imageName: "android_ota_success",
                    title: L10n.t("升级成功", "Update Successful"),
                    subtitle: L10n.t("快去体验新版本吧！", "Enjoy the new version!")
                )
            } else if let unconfirmedMessage {
                resultView(
                    imageName: nil,
                    title: L10n.t("升级结果待确认", "Update Awaiting Confirmation"),
                    subtitle: unconfirmedMessage
                )
            } else if let failureMessage {
                resultView(
                    imageName: "android_ota_failure",
                    title: L10n.t("升级失败", "Update Failed"),
                    subtitle: L10n.t("很抱歉，本次更新未能成功。", "Sorry, this update was unsuccessful."),
                    detail: failureMessage
                )
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        currentVersionCard
                        centerSection
                        contentSection
                        if needsGen1Wifi, !isUpgradingForThisPage {
                            gen1WifiSection
                        }
                        if isUpgradingForThisPage {
                            warningSection
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }

                if !isUpgradingForThisPage {
                    warningSection
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
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
            if isOfferDeviceAvailable { ble.refreshDeviceVersionsAndStorage() }
            loadFileSizeIfNeeded()
            autofillWifiSSIDIfNeeded()
        }
        .onChangeCompat(of: isOfferDeviceAvailable) { available in
            if available {
                ble.refreshDeviceVersionsAndStorage()
            }
        }
        .onChangeCompat(of: isUpgradingForThisPage) { upgrading in
            if upgrading { wifiSSIDReader.cancel() }
        }
        .onDisappear {
            wifiSSIDReader.cancel()
            gen1WifiPassword = ""
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
                    Image("android_settings_back")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 21, height: 21)
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
            if isUpgradingForThisPage, let progress = otaManager.overallProgress {
                OtaCircularProgressView(progress: progress)
                Text(otaManager.currentStatusText)
                    .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
            } else {
                Image("android_upgrade")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 136, height: 136)
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
                Text(releaseNoteLine(line, index: index))
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func releaseNoteLine(_ line: String, index: Int) -> String {
        let hasNumber = line.range(of: #"^\d+[.、．)]"#, options: .regularExpression) != nil
        return hasNumber ? line : "\(index + 1). \(line)"
    }

    private var warningSection: some View {
        VStack(spacing: 12) {
            if isGen1BluetoothRecovery {
                Text(L10n.t("上次蓝牙固件升级未完成，本次将重新写入固件以恢复设备。当前版本读取失败不影响恢复升级。", "The previous Bluetooth firmware update did not finish. This update will rewrite the firmware to recover the glasses. Recovery is available even if the current version cannot be read."))
                    .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if needsGen1Wifi {
                Text(L10n.t("每次升级都会重新为眼镜配置可上网的 2.4 GHz Wi-Fi。升级期间请保持眼镜供电，完成后将自动重连并核对版本。", "Each update configures the glasses for a 2.4 GHz Wi-Fi network with internet access. Keep the glasses powered throughout the update. The app will reconnect and verify the version afterward."))
                    .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            Text(attributedBatteryWarning)
                .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Image("android_ota_warning")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text(L10n.t("更新过程中眼镜系统功能不可使用", "Glasses features are unavailable during the update"))
                    .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
    }

    private var attributedBatteryWarning: AttributedString {
        var text = AttributedString(kind == .firmware
            ? L10n.t("OTA升级需要眼镜保持", "OTA update requires ")
            : L10n.t("OTA升级需要", "OTA update requires "))
        text.foregroundColor = .black
        if kind == .firmware {
            var connection = AttributedString(L10n.t("Wi-Fi连接", "Wi-Fi"))
            connection.foregroundColor = .red
            text.append(connection)
            text.append(AttributedString(L10n.t("和", " and ")))
        }
        let minimum = entryGeneration == .gen2
            ? FirmwareUpgradeBatteryPolicy.gen2MinimumPercent
            : FirmwareUpgradeBatteryPolicy.gen1MinimumPercent
        var highlight = AttributedString(L10n.t("眼镜电量≥\(minimum)%", "glasses battery ≥\(minimum)%"))
        highlight.foregroundColor = .red
        text.append(highlight)
        return text
    }

    private var gen1WifiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("为眼镜连接 Wi-Fi", "Connect Glasses to Wi-Fi"))
                .font(AppTheme.notoSansSC(size: 15, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
            Text(L10n.t("请输入可上网的 2.4 GHz Wi-Fi 名称与密码。开放网络可不填密码。", "Enter the name and password of a 2.4 GHz Wi-Fi network with internet access. Leave the password empty for an open network."))
                .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextField(L10n.t("Wi-Fi 名称（SSID）", "Wi-Fi Name (SSID)"), text: Binding(
                get: { gen1WifiSSID },
                set: { value in
                    hasEditedGen1WifiSSID = true
                    gen1WifiSSID = value
                    wifiSSIDReader.cancel()
                }
            ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField(L10n.t("Wi-Fi 密码", "Wi-Fi Password"), text: $gen1WifiPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
        }
        .padding(16)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
        .disabled(!isOfferDeviceAvailable)
    }

    private func autofillWifiSSIDIfNeeded() {
        guard needsGen1Wifi, !isUpgradingForThisPage,
              !(otaManager.state.isTerminal && isStateForCurrentOffer),
              !hasEditedGen1WifiSSID, gen1WifiSSID.isEmpty else { return }
        wifiSSIDReader.start { ssid in
            guard needsGen1Wifi, !isUpgradingForThisPage,
                  !hasEditedGen1WifiSSID, gen1WifiSSID.isEmpty,
                  let ssid else { return }
            gen1WifiSSID = ssid
        }
    }

    private func resultView(imageName: String?, title: String, subtitle: String, detail: String? = nil) -> some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if let imageName {
                        Image(imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 136, height: 136)
                    }

                    Text(title)
                        .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                        .foregroundStyle(AppTheme.primaryText)
                        .padding(.top, 32)

                    Text(subtitle)
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                        .padding(.top, 8)

                    if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, detail != subtitle {
                        Text(detail)
                            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.top, 16)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, max(48, geometry.size.height * 0.16))
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
    }

    private func startUpgrade() {
        guard !otaManager.isUpgrading else { return }
        guard isOfferDeviceAvailable else {
            batteryAlertMessage = L10n.t("请先连接对应的已绑定眼镜", "Please connect the bound glasses for this update first")
            return
        }
        guard !ble.deviceVersionQueryFailed || isGen1BluetoothRecovery else {
            batteryAlertMessage = L10n.t("未读取到完整版本信息，请返回并重新连接眼镜后重试。", "Complete version information was not received. Go back, reconnect your glasses, and try again.")
            return
        }
        // Gen1 main firmware queries 0x05 before enforcing its 80% gate. A stale
        // cached low value must not prevent that fresh query from being sent.
        if !needsGen1Wifi, let message = ble.firmwareUpgradeBatteryAlertMessage {
            batteryAlertMessage = message
            ble.queryBatteryOnly()
            return
        }

        var gen1Wifi: Gen1FirmwareWifiCredentials?
        if needsGen1Wifi {
            do {
                _ = try Gen1FirmwareUpdateProtocol.wifiPayload(ssid: gen1WifiSSID, password: gen1WifiPassword)
                gen1Wifi = Gen1FirmwareWifiCredentials(ssid: gen1WifiSSID, password: gen1WifiPassword)
            } catch {
                batteryAlertMessage = error.localizedDescription
                return
            }
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
                importManager: importManager,
                gen1Wifi: gen1Wifi
            )
            gen1WifiPassword = ""
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
        if ble.deviceVersionQueryFailed {
            return L10n.t("读取失败", "Read failed")
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
        String(format: "%.1fM", Double(bytes) / 1024 / 1024)
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
