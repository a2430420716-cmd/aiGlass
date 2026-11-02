import SwiftUI

struct GlassesFirmwareUpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var updateCoordinator: DeviceFirmwareUpdateCoordinator
    @EnvironmentObject private var otaManager: BluetoothOtaUpgradeManager

    @ObservedObject private var ble: AstraA1BleManager
    @State private var showsLatestVersionMessage = false
    @State private var versionStatusMessage = ""
    @State private var latestVersionMessageTask: Task<Void, Never>?

    init(ble: AstraA1BleManager) {
        _ble = ObservedObject(wrappedValue: ble)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 72) {
                    upgradeIcon
                    versionCard
                    if ble.deviceVersionQueryFailed, !ble.isQueryingDeviceVersionsAndStorage {
                        versionQueryFailure
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 56)
                .padding(.bottom, 32)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .overlay {
            if showsLatestVersionMessage {
                Text(versionStatusMessage)
                    .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .allowsHitTesting(false)
            }
        }
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .onAppear {
            ble.ensureConnected(reason: "firmwareUpgrade")
            refreshVersionsFromBLE()
        }
        .onDisappear {
            latestVersionMessageTask?.cancel()
            latestVersionMessageTask = nil
            showsLatestVersionMessage = false
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
        .onChangeCompat(of: authSession.userInfo?.bluetoothBySerialNumber.count ?? 0) { _ in refreshState() }
        .onChangeCompat(of: authSession.userInfo?.firmwareBySerialNumber.count ?? 0) { _ in refreshState() }
        .onChangeCompat(of: otaManager.state) { newState in
            if newState.isTerminal {
                refreshState()
            }
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("眼镜固件升级", "Glasses Firmware Update"))
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
            .frame(width: 136, height: 136)
        .frame(maxWidth: .infinity)
    }

    private var versionCard: some View {
        VStack(spacing: 8) {
            bluetoothVersionRow
            firmwareVersionRow
        }
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
                    title: L10n.t("蓝牙版本", "Bluetooth Version"),
                    version: displayVersion(ble.deviceVersion2800),
                    hasUpdate: !ble.deviceVersionQueryFailed
                )
            }
            .buttonStyle(.plain)
            .disabled(!ble.isDeviceAvailable || ble.deviceVersionQueryFailed)
        } else {
            Button { showVersionStatus(for: .bluetooth) } label: {
                versionRowLabel(
                    title: L10n.t("蓝牙版本", "Bluetooth Version"),
                    version: displayVersion(ble.deviceVersion2800),
                    hasUpdate: false
                )
            }
            .buttonStyle(.plain)
            .disabled(!ble.isDeviceAvailable || ble.deviceVersionQueryFailed || ble.isQueryingDeviceVersionsAndStorage)
        }
    }

    @ViewBuilder
    private var firmwareVersionRow: some View {
        if let offer = updateCoordinator.firmwareUpdate {
            NavigationLink {
                DeviceOtaUpgradeDetailView(kind: .firmware, offer: offer, ble: ble)
            } label: {
                versionRowLabel(
                    title: L10n.t("固件版本", "Firmware Version"),
                    version: displayVersion(ble.deviceVersion6350),
                    hasUpdate: !ble.deviceVersionQueryFailed
                )
            }
            .buttonStyle(.plain)
            .disabled(!ble.isDeviceAvailable || ble.deviceVersionQueryFailed)
        } else {
            Button { showVersionStatus(for: .firmware) } label: {
                versionRowLabel(
                    title: L10n.t("固件版本", "Firmware Version"),
                    version: displayVersion(ble.deviceVersion6350),
                    hasUpdate: false
                )
            }
            .buttonStyle(.plain)
            .disabled(!ble.isDeviceAvailable || ble.deviceVersionQueryFailed || ble.isQueryingDeviceVersionsAndStorage)
        }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func showVersionStatus(for kind: OtaUpgradeKind) {
        let entries = kind == .bluetooth
            ? authSession.userInfo?.bluetoothBySerialNumber
            : authSession.userInfo?.firmwareBySerialNumber
        let currentVersion = kind == .bluetooth ? ble.deviceVersion2800 : ble.deviceVersion6350
        let keys = [ble.deviceSN, ble.deviceBluetoothIdentifier].compactMap { $0?.lowercased() }
        let server = entries?.first { key, _ in keys.contains(key.lowercased()) }?.value
        let normalize: (String) -> String = { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        }
        if let currentVersion, let server, normalize(currentVersion) == normalize(server.version) {
            versionStatusMessage = L10n.t("当前已是最新版本", "Already up to date")
        } else {
            versionStatusMessage = L10n.t("暂无可用升级", "No update available")
        }
        latestVersionMessageTask?.cancel()
        showsLatestVersionMessage = true
        latestVersionMessageTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            showsLatestVersionMessage = false
        }
    }

    private func displayVersion(_ raw: String?) -> String {
        if ble.isQueryingDeviceVersionsAndStorage,
           raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return L10n.t("加载中...", "Loading...")
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
