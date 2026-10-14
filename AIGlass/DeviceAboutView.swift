import SwiftUI

/// 眼镜「关于设备」页：展示 BLE `getdevinfo` 可读字段及账号绑定信息。
struct DeviceAboutView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession
    @ObservedObject private var ble: AstraA1BleManager
    private let boundSerialNumber: String?

    init(ble: AstraA1BleManager, boundSerialNumber: String? = nil) {
        _ble = ObservedObject(wrappedValue: ble)
        self.boundSerialNumber = boundSerialNumber
    }

    private var boundDevice: UserDevice? {
        if let target = normalized(boundSerialNumber) {
            return authSession.userInfo?.device.first {
                normalized($0.serialNumber) == target
            }
        }
        return authSession.userInfo?.device.first
    }

    private var glassImageName: String {
        boundDevice?.cardImageName ?? "glass2"
    }

    private var isAboutDeviceAvailable: Bool {
        guard let boundDevice else { return false }
        return ble.isDeviceAvailable && ble.matchesCurrentDevice(
            serialNumber: boundDevice.serialNumber,
            hardwareSN: boundDevice.hardwareSN
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    Image(glassImageName)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280, maxHeight: 120)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    identityCard
                    systemCard
                    storageCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .onAppear {
            ble.ensureConnected(reason: "aboutDevice")
            refreshDeviceInfo()
        }
        .onChangeCompat(of: isAboutDeviceAvailable) { available in
            if available {
                refreshDeviceInfo()
            }
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("关于设备", "About Device"))
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

    private var identityCard: some View {
        AboutInfoCard {
            DeviceAboutRow(
                title: L10n.t("设备名称", "Device Name"),
                value: displayName,
                showsChevron: true
            )
            AboutCardDivider()
            DeviceAboutRow(title: L10n.t("设备型号", "Model"), value: displayHardwareModel)
            AboutCardDivider()
            DeviceAboutRow(title: L10n.t("序列号", "Serial Number"), value: displaySerialNumber)
            AboutCardDivider()
            DeviceAboutRow(title: L10n.t("蓝牙标识", "Bluetooth Identifier"), value: displayMACAddress)
        }
    }

    private var systemCard: some View {
        AboutInfoCard {
            DeviceAboutRow(title: L10n.t("系统名称", "System Name"), value: displaySystemName)
            AboutCardDivider()
            DeviceAboutRow(title: L10n.t("蓝牙版本", "Bluetooth Version"), value: displayBluetoothVersion)
            AboutCardDivider()
            DeviceAboutRow(title: L10n.t("固件版本", "Firmware Version"), value: displayFirmwareVersion)
        }
    }

    private var storageCard: some View {
        AboutInfoCard {
            DeviceAboutRow(title: L10n.t("存储空间", "Storage"), value: displayStorage)
        }
    }

    // MARK: - Display values

    private var displayName: String {
        (isAboutDeviceAvailable ? nonEmpty(ble.deviceName) : nil)
            ?? (isAboutDeviceAvailable ? nonEmpty(ble.currentPeripheralName) : nil)
            ?? nonEmpty(boundDevice?.deviceName)
            ?? nonEmpty(boundDevice?.displayName)
            ?? placeholder
    }

    /// BLE `model` 为硬件型号（如 MCA010）；API `model_name` 为销售型号（如 G5T71）。
    private var displayHardwareModel: String {
        isAboutDeviceAvailable ? (nonEmpty(ble.deviceModel) ?? placeholder) : placeholder
    }

    private var displaySerialNumber: String {
        DeviceIdentityPresentation.hardwareSN(
            candidates: [
                isAboutDeviceAvailable ? ble.deviceSN : nil,
                (boundDevice?.serialNumber).flatMap { ble.cachedHardwareSN(forSerialNumber: $0) },
                boundDevice?.hardwareSN
            ],
            bluetoothID: boundDevice?.serialNumber
        ) ?? placeholder
    }

    /// iOS 不向第三方 App 提供 BLE 真实 MAC；展示 CoreBluetooth 外设 UUID（绑定接口 serial_number 同值）。
    private var displayMACAddress: String {
        (isAboutDeviceAvailable ? nonEmpty(ble.deviceBluetoothIdentifier) : nil)
            ?? nonEmpty(boundDevice?.serialNumber) ?? placeholder
    }

    /// 协议未提供系统名称字段；MOCO 眼镜固件系统名为 MOS。
    private var displaySystemName: String {
        isAboutDeviceAvailable ? "MOS" : placeholder
    }

    private var displayBluetoothVersion: String {
        guard isAboutDeviceAvailable else { return placeholder }
        if ble.isQueryingAboutDeviceInfo, ble.deviceVersion2800 == nil {
            return L10n.t("加载中...", "Loading...")
        }
        return nonEmpty(ble.deviceVersion2800) ?? placeholder
    }

    private var displayFirmwareVersion: String {
        guard isAboutDeviceAvailable else { return placeholder }
        if ble.isQueryingAboutDeviceInfo, ble.deviceVersion6350 == nil {
            return L10n.t("加载中...", "Loading...")
        }
        return nonEmpty(ble.deviceVersion6350) ?? placeholder
    }

    private var displayStorage: String {
        guard isAboutDeviceAvailable else { return placeholder }
        if ble.isQueryingAboutDeviceInfo, ble.deviceStorage == nil {
            return L10n.t("加载中...", "Loading...")
        }
        if ble.deviceStorage != nil {
            return ble.deviceStorageDisplay
        }
        return placeholder
    }

    private var placeholder: String { "—" }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func normalized(_ value: String?) -> String? {
        nonEmpty(value)?.lowercased()
    }

    private func refreshDeviceInfo() {
        if isAboutDeviceAvailable {
            ble.queryAboutDeviceInfo()
        }
    }
}

private struct AboutInfoCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct AboutCardDivider: View {
    var body: some View {
        Divider()
            .overlay(Color(red: 0.94, green: 0.94, blue: 0.94))
    }
}

private struct DeviceAboutRow: View {
    let title: String
    let value: String
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 8)

            Text(value)
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(.vertical, 16)
    }
}

#Preview {
    CompatibleNavigationStack {
        DeviceAboutView(ble: AstraA1BleManager())
            .environmentObject(AuthSession())
    }
}
