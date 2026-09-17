import SwiftUI

struct GlassesFirmwareUpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var updateCoordinator: DeviceFirmwareUpdateCoordinator
    @EnvironmentObject private var otaManager: BluetoothOtaUpgradeManager

    @ObservedObject private var ble: AstraA1BleManager

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
                }
                .padding(.horizontal, 20)
                .padding(.top, 32)
                .padding(.bottom, 32)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .onAppear {
            ble.ensureConnected(reason: "firmwareUpgrade")
            refreshVersionsFromBLE()
        }
        .onChangeCompat(of: ble.isReady) { ready in
            if ready { refreshVersionsFromBLE() }
        }
        .onChangeCompat(of: ble.deviceStorage) { _ in refreshState() }
        .onChangeCompat(of: ble.deviceVersion2800) { _ in refreshState() }
        .onChangeCompat(of: ble.deviceVersion6350) { _ in refreshState() }
        .onChangeCompat(of: ble.isQueryingDeviceVersionsAndStorage) { isQuerying in
            if !isQuerying { refreshState() }
        }
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

    @ViewBuilder
    private var bluetoothVersionRow: some View {
        if let offer = updateCoordinator.bluetoothUpdate {
            NavigationLink {
                DeviceOtaUpgradeDetailView(kind: .bluetooth, offer: offer, ble: ble)
            } label: {
                versionRowLabel(
                    title: L10n.t("蓝牙版本", "Bluetooth Version"),
                    version: displayVersion(ble.deviceVersion2800),
                    hasUpdate: true
                )
            }
            .buttonStyle(.plain)
        } else {
            versionRowLabel(
                title: L10n.t("蓝牙版本", "Bluetooth Version"),
                version: displayVersion(ble.deviceVersion2800),
                hasUpdate: false
            )
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
                    hasUpdate: true
                )
            }
            .buttonStyle(.plain)
        } else {
            versionRowLabel(
                title: L10n.t("固件版本", "Firmware Version"),
                version: displayVersion(ble.deviceVersion6350),
                hasUpdate: false
            )
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
        .padding(.vertical, 18)
    }

    private func displayVersion(_ raw: String?) -> String {
        if ble.isQueryingDeviceVersionsAndStorage,
           raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return L10n.t("加载中...", "Loading...")
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "—" }
        if trimmed.hasPrefix("V") || trimmed.hasPrefix("v") { return trimmed }
        return "V\(trimmed)"
    }

    private func refreshVersionsFromBLE() {
        if ble.isReady {
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
