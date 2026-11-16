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
        _entryGeneration = State(initialValue: offer.isGen1BluetoothRecovery ? .gen1G5K61 : ble.deviceGeneration)
    }

    private var needsGen1Wifi: Bool {
        entryGeneration == .gen1G5K61 && kind == .firmware
    }

    private var isGen1BluetoothRecovery: Bool {
        kind == .bluetooth && entryGeneration == .gen1G5K61
            && offer.isGen1BluetoothRecovery
            && ble.savedPeripheralUUIDString == offer.serialNumber
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

    private var loaderRecoveryRecord: Gen1BluetoothOtaRecoveryStore.Record? {
        guard kind == .bluetooth, entryGeneration == .gen1G5K61,
              let id = ble.savedPeripheralUUIDString.flatMap(UUID.init(uuidString:)),
              (isGen1BluetoothRecovery || (isStateForCurrentOffer && otaManager.activeTargetID == id)),
              let record = Gen1BluetoothOtaRecoveryStore().record(for: id),
              record.permitsLoaderRecovery(savedID: ble.savedPeripheralUUIDString.flatMap(UUID.init(uuidString:)),
                                           accountID: ble.gen1ImportAccount(for: id)) else { return nil }
        return record
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
                    title: L10n.t("升级成功", "Update successful"),
                    subtitle: L10n.t("快去体验新版本吧！", "Try the new version now!")
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
                    title: L10n.t("升级失败", "Update failed"),
                    subtitle: L10n.t("很抱歉，本次更新未能成功。", "Sorry, the update could not be completed."),
                    detail: failureMessage
                )
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        currentVersionCard
                        centerSection
                        if isUpgradingForThisPage, let wifi = otaManager.manualWifiCredential {
                            manualWifiSection(wifi)
                        }
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
            if isStateForCurrentOffer { otaManager.cancelManualWifiConnection() }
            if needsGen1Wifi, isStateForCurrentOffer { otaManager.cancelGen1WifiProvision() }
        }
        .alert(L10n.t("Wi-Fi 配网成功", "Wi-Fi Configured"), isPresented: Binding(
            get: { needsGen1Wifi && isStateForCurrentOffer && otaManager.isAwaitingGen1WifiConfirmation },
            set: { _ in }
        )) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {
                otaManager.cancelGen1WifiProvision()
            }
            Button(L10n.t("下一步", "Next")) {
                otaManager.confirmGen1WifiProvision()
            }
        } message: {
            Text(L10n.t("眼镜已连接 Wi-Fi，点击下一步开始固件升级。", "The glasses have connected to Wi-Fi. Tap Next to start the firmware update."))
        }
        .alert(L10n.t("无法升级", "Unable to Update"), isPresented: Binding(
            get: { batteryAlertMessage != nil },
            set: { if !$0 { batteryAlertMessage = nil } }
        )) {
            Button(L10n.t("知道了", "Got it"), role: .cancel) {}
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
            Text(L10n.t("\(kind.contentTitlePrefix)\(displayVersion(offer.serverInfo.version))更新内容：", "\(kind.contentTitlePrefix) \(displayVersion(offer.serverInfo.version)) Release notes:"))
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
                Text(L10n.t("上次蓝牙固件升级未完成，请先为眼镜充足电并保持供电，再恢复升级。恢复期间请保持眼镜开机并靠近手机。", "The previous Bluetooth firmware update did not finish. Charge the glasses and keep them powered before recovery. Keep them on and close to your phone during recovery."))
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
                Text(L10n.t("更新过程中眼镜系统功能不可使用", "Glasses system features are unavailable during the update"))
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
            var connection = AttributedString(L10n.t("Wi-Fi连接", "Wi-Fi connection"))
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
            Text(L10n.t("请输入可上网的 2.4 GHz Wi-Fi 名称与密码，密码为必填项。", "Enter the name and password of a 2.4 GHz Wi-Fi network with internet access. A password is required."))
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
            Text(L10n.t("立即升级", "Update now"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isOfferDeviceAvailable && loaderRecoveryRecord == nil)
    }

    private func manualWifiSection(_ wifi: Gen2OtaWifiConnectionSession.Credential) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("手动连接眼镜 Wi-Fi", "Connect to Glasses Wi-Fi"))
                .font(AppTheme.notoSansSC(size: 15, weight: .bold))
            Text(L10n.t("自动连接未成功。请在手机“设置 → Wi-Fi”中加入以下网络，返回 App 后点击继续。请在 3 分钟内点击继续。", "Automatic connection failed. Open Settings → Wi-Fi, join the network below, then return and tap Continue within 3 minutes."))
                .font(AppTheme.notoSansSC(size: 13, weight: .regular))
            Text("Wi-Fi: \(wifi.ssid)")
                .textSelection(.enabled)
            if !wifi.password.isEmpty {
                Text(L10n.t("密码：\(wifi.password)", "Password: \(wifi.password)"))
                    .textSelection(.enabled)
            }
            if let error = otaManager.manualWifiError {
                Text(error)
                    .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.accent)
            }
            Button(action: otaManager.confirmManualWifiConnection) {
                HStack {
                    if otaManager.isCheckingManualWifi { ProgressView() }
                    Text(L10n.t("已连接，继续", "Connected, Continue"))
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primaryText)
            .disabled(otaManager.isCheckingManualWifi)
            Button(L10n.t("取消本次升级", "Cancel Update"), role: .cancel,
                   action: otaManager.cancelManualWifiConnection)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(otaManager.isCheckingManualWifi)
        }
        .foregroundStyle(AppTheme.primaryText)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
                    if failureMessage != nil, let record = loaderRecoveryRecord {
                        Button(L10n.t("恢复蓝牙升级", "Recover Bluetooth Update")) {
                            otaManager.startGen1BluetoothRecovery(record: record, ble: ble, importManager: importManager)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.primaryText)
                        .frame(minHeight: 48)
                        .padding(.top, 24)
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
        if !isOfferDeviceAvailable, let record = loaderRecoveryRecord {
            otaManager.startGen1BluetoothRecovery(record: record, ble: ble, importManager: importManager)
            return
        }
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
                guard !gen1WifiPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    batteryAlertMessage = L10n.t("请输入 Wi-Fi 密码", "Please enter the Wi-Fi password")
                    return
                }
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
            return L10n.t("加载中...", "Loading…")
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
