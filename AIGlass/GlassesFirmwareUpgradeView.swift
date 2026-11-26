import SwiftUI

struct GlassesFirmwareUpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var updateCoordinator: DeviceFirmwareUpdateCoordinator
    @EnvironmentObject private var otaManager: BluetoothOtaUpgradeManager

    @ObservedObject private var ble: AstraA1BleManager
    @State private var showsLatestVersionToast = false

    init(ble: AstraA1BleManager) {
        _ble = ObservedObject(wrappedValue: ble)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    upgradeIcon
                    versionCard
                    if ble.deviceVersionQueryFailed, !ble.isQueryingDeviceVersionsAndStorage {
                        versionQueryFailure
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 32)
                .padding(.bottom, 32)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .overlay(alignment: .bottom) {
            if showsLatestVersionToast {
                Text(L10n.t("当前已是最新版本", "Already  up to date"))
                    .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.78))
                    .clipShape(Capsule())
                    .padding(.horizontal, 20)
                    .padding(.bottom, 72)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsLatestVersionToast)
        .task(id: showsLatestVersionToast) {
            guard showsLatestVersionToast else { return }
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                showsLatestVersionToast = false
            } catch {}
        }
        .onAppear {
            ble.ensureConnected(reason: "firmwareUpgrade")
            refreshVersionsFromBLE()
        }
        .task {
            await authSession.refreshUserInfo()
            guard !Task.isCancelled else { return }
            refreshState()
        }
        .onChangeCompat(of: ble.isDeviceAvailable) { available in
            if available { refreshVersionsFromBLE() }
            else { refreshState() }
        }
        .onChangeCompat(of: ble.deviceStorage) { _ in refreshState() }
        .onChangeCompat(of: ble.deviceVersion2800) { _ in refreshState() }
        .onChangeCompat(of: ble.deviceVersion6350) { _ in refreshState() }
        .onChangeCompat(of: ble.isQueryingDeviceVersionsAndStorage) { isQuerying in
            if !isQuerying { refreshState() }
        }
        .onChangeCompat(of: ble.deviceVersionQueryFailed) { _ in refreshState() }
        .onChangeCompat(of: authSession.userInfo?.bluetoothBySerialNumber) { _ in refreshState() }
        .onChangeCompat(of: authSession.userInfo?.firmwareBySerialNumber) { _ in refreshState() }
        .onChangeCompat(of: otaManager.state) { newState in
            if newState.isTerminal {
                refreshState()
            }
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("眼镜固件升级", "Glasses firmware upgrade"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button { dismiss() } label: {
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

    private var upgradeIcon: some View {
        Image("android_upgrade")
            .resizable()
            .scaledToFit()
            .frame(width: 120, height: 120)
        .frame(maxWidth: .infinity)
    }

    private var versionCard: some View {
        VStack(spacing: 0) {
            bluetoothVersionRow
            Divider().overlay(Color(red: 0.94, green: 0.94, blue: 0.94))
            firmwareVersionRow
        }
        .padding(.horizontal, 16)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var versionQueryFailure: some View {
        VStack(spacing: 12) {
            Text(L10n.t("未收到完整版本信息，请重新连接眼镜后重试。", "Complete version information was not received. Reconnect your glasses and try again."))
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)

            Button(L10n.t("重试", "Retry"), action: refreshVersionsFromBLE)
                .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                .disabled(!ble.isDeviceAvailable || ble.isQueryingDeviceVersionsAndStorage || ble.isQueryingAboutDeviceInfo)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var bluetoothVersionRow: some View {
        if let offer = updateCoordinator.bluetoothUpdate {
            NavigationLink {
                DeviceOtaUpgradeDetailView(kind: .bluetooth, offer: offer, ble: ble)
            } label: {
                versionRowLabel(
                    title: L10n.t("蓝牙版本", "Bluetooth version"),
                    version: displayVersion(ble.deviceVersion2800),
                    hasUpdate: !ble.deviceVersionQueryFailed || offer.isGen1BluetoothRecovery
                )
            }
            .buttonStyle(.plain)
            .disabled((!ble.isDeviceAvailable && !canOpenLoaderRecovery(offer))
                      || (ble.deviceVersionQueryFailed && !offer.isGen1BluetoothRecovery))
        } else {
            Button {
                showsLatestVersionToast = true
            } label: {
                versionRowLabel(
                    title: L10n.t("蓝牙版本", "Bluetooth version"),
                    version: displayVersion(ble.deviceVersion2800),
                    hasUpdate: false
                )
            }
            .buttonStyle(.plain)
            .disabled(!canConfirmLatestVersion(
                ble.deviceVersion2800,
                serverVersions: authSession.userInfo?.bluetoothBySerialNumber ?? [:]
            ))
        }
    }

    @ViewBuilder
    private var firmwareVersionRow: some View {
        if let offer = updateCoordinator.firmwareUpdate {
            NavigationLink {
                DeviceOtaUpgradeDetailView(kind: .firmware, offer: offer, ble: ble)
            } label: {
                versionRowLabel(
                    title: L10n.t("固件版本", "Firmware version"),
                    version: displayVersion(ble.deviceVersion6350),
                    hasUpdate: !ble.deviceVersionQueryFailed
                )
            }
            .buttonStyle(.plain)
            .disabled(!ble.isDeviceAvailable || ble.deviceVersionQueryFailed)
        } else {
            Button {
                showsLatestVersionToast = true
            } label: {
                versionRowLabel(
                    title: L10n.t("固件版本", "Firmware version"),
                    version: displayVersion(ble.deviceVersion6350),
                    hasUpdate: false
                )
            }
            .buttonStyle(.plain)
            .disabled(!canConfirmLatestVersion(
                ble.deviceVersion6350,
                serverVersions: authSession.userInfo?.firmwareBySerialNumber ?? [:]
            ))
        }
    }

    private func canConfirmLatestVersion(_ rawVersion: String?, serverVersions: [String: DeviceOTAInfo]) -> Bool {
        guard ble.isDeviceAvailable,
              !ble.isQueryingDeviceVersionsAndStorage,
              !ble.isQueryingAboutDeviceInfo,
              !ble.deviceVersionQueryFailed,
              authSession.isLoggedIn,
              !authSession.isLoadingUserInfo,
              authSession.userInfoError == nil,
              !otaManager.isUpgrading,
              let version = rawVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty,
              !FirmwareVersionComparator.isPlaceholderVersion(version) else { return false }

        let keys = [ble.deviceSN, ble.deviceBluetoothIdentifier]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for key in keys {
            if let serverInfo = serverVersions[key]
                ?? serverVersions.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                let serverVersion = serverInfo.version.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !serverVersion.isEmpty else { return false }
                return !FirmwareVersionComparator.isServerVersionNewer(serverVersion, than: version)
            }
        }
        return false
    }

    private func canOpenLoaderRecovery(_ offer: DeviceFirmwareUpdateCoordinator.UpdateOffer) -> Bool {
        guard offer.isGen1BluetoothRecovery,
              let targetID = UUID(uuidString: offer.serialNumber),
              let record = Gen1BluetoothOtaRecoveryStore().record(for: targetID) else { return false }
        return record.permitsLoaderRecovery(
            savedID: ble.savedPeripheralUUIDString.flatMap(UUID.init(uuidString:)),
            accountID: ble.gen1ImportAccount(for: targetID)
        )
    }

    private func versionRowLabel(title: String, version: String, hasUpdate: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                    .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)

                if hasUpdate {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                }
            }

            Spacer(minLength: 8)

            Text(version)
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)

            if hasUpdate {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(.vertical, 18)
        .contentShape(Rectangle())
    }

    private func displayVersion(_ raw: String?) -> String {
        if ble.isQueryingDeviceVersionsAndStorage,
           raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return L10n.t("加载中...", "Loading…")
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return ble.deviceVersionQueryFailed ? L10n.t("读取失败", "Read failed") : "—"
        }
        if trimmed.hasPrefix("V") || trimmed.hasPrefix("v") { return trimmed }
        return "V\(trimmed)"
    }

    private func refreshVersionsFromBLE() {
        if ble.isDeviceAvailable {
            ble.refreshDeviceVersionsAndStorage(includeSerialNumber: true)
        }
        refreshState()
    }

    private func refreshState() {
        updateCoordinator.refreshAvailability(
            authSession: authSession,
            ble: ble,
            otaManager: otaManager
        )
    }
}
