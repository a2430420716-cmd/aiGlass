import Combine
import Foundation
import SwiftUI

@MainActor
final class DeviceFirmwareUpdateCoordinator: ObservableObject {
    struct UpdateOffer: Equatable, Identifiable {
        let serialNumber: String
        let currentVersion: String
        let serverInfo: DeviceOTAInfo
        var isGen1BluetoothRecovery = false
        var id: String { "\(serialNumber)|\(serverInfo.version)|\(isGen1BluetoothRecovery)" }
    }

    @Published private(set) var bluetoothUpdate: UpdateOffer?
    @Published private(set) var firmwareUpdate: UpdateOffer?

    var hasAnyUpdate: Bool {
        bluetoothUpdate != nil || firmwareUpdate != nil
    }

    private var scheduledRefreshTask: Task<Void, Never>?

    func scheduleRefresh(
        authSession: AuthSession,
        ble: AstraA1BleManager,
        otaManager: BluetoothOtaUpgradeManager
    ) {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            refreshAvailability(authSession: authSession, ble: ble, otaManager: otaManager)
        }
    }

    func beginBluetoothUpgrade(
        serverInfo: DeviceOTAInfo,
        authorization: String?,
        ble: AstraA1BleManager,
        otaManager: BluetoothOtaUpgradeManager,
        importManager: MediaImportManager
    ) {
        guard ble.isDeviceAvailable else { return }
        print("[DeviceOTA] start bluetooth upgrade target=\(serverInfo.version)")
        otaManager.startBluetoothUpgrade(
            serverInfo: serverInfo,
            authorization: authorization,
            ble: ble,
            importManager: importManager
        )
    }

    func beginFirmwareUpgrade(
        serverInfo: DeviceOTAInfo,
        authorization: String?,
        ble: AstraA1BleManager,
        otaManager: BluetoothOtaUpgradeManager,
        importManager: MediaImportManager,
        gen1Wifi: Gen1FirmwareWifiCredentials? = nil
    ) {
        guard ble.isDeviceAvailable else { return }
        print("[DeviceOTA] start firmware upgrade target=\(serverInfo.version)")
        otaManager.startFirmwareUpgrade(
            serverInfo: serverInfo,
            authorization: authorization,
            ble: ble,
            importManager: importManager,
            gen1Wifi: gen1Wifi
        )
    }

    func refreshAvailability(
        authSession: AuthSession,
        ble: AstraA1BleManager,
        otaManager: BluetoothOtaUpgradeManager
    ) {
        // 结果页关闭前保留当前升级入口，避免版本刷新移除 NavigationLink，
        // 导致详情页在收到 completed/failed 后立刻被 SwiftUI 弹回。
        guard !otaManager.isUpgrading, !otaManager.state.isTerminal else { return }
        // An interrupted Gen1 Bluetooth image may not answer version queries.
        // Evaluate recovery before the ordinary fresh-version guards.
        if authSession.isLoggedIn,
           let identifier = ble.savedPeripheralUUIDString.flatMap(UUID.init(uuidString:)),
           let record = Gen1BluetoothOtaRecoveryStore().record(for: identifier),
           (record.permitsLoaderRecovery(savedID: identifier, accountID: ble.gen1ImportAccount(for: identifier))
            || (ble.isDeviceAvailable && ble.deviceGeneration == .gen1G5K61
                && ble.deviceBluetoothIdentifier == identifier.uuidString)) {
            // A newer publication must not replace a partially submitted image.
            let recoveryInfo = DeviceOTAInfo(version: record.version, downloadURL: record.downloadURL, content: record.content)
            bluetoothUpdate = UpdateOffer(
                serialNumber: identifier.uuidString,
                currentVersion: ble.deviceVersion2800 ?? "",
                serverInfo: recoveryInfo, isGen1BluetoothRecovery: true
            )
            firmwareUpdate = nil
            return
        }
        guard !ble.isQueryingDeviceVersionsAndStorage, !ble.isQueryingAboutDeviceInfo else { return }
        // 保留导航节点，避免读取失败弹回详情页；页面负责禁用升级入口。
        guard !ble.deviceVersionQueryFailed else { return }
        guard authSession.isLoggedIn else {
            bluetoothUpdate = nil
            firmwareUpdate = nil
            return
        }
        guard ble.isDeviceAvailable else {
            bluetoothUpdate = nil
            firmwareUpdate = nil
            return
        }

        // 服务端 arr_* .serial_number：现网多为眼镜 SN（如 G5T7…）；旧数据可能是 iOS 外设 UUID。
        // 两边都试，避免查不到 → bleServer=nil 不提示升级。
        let deviceSN = ble.deviceSN?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bleUUID = ble.deviceBluetoothIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bluetoothVersion = ble.deviceVersion2800?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firmwareVersion = ble.deviceVersion6350?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if (deviceSN.isEmpty && bleUUID.isEmpty) || bluetoothVersion.isEmpty || firmwareVersion.isEmpty {
            if !ble.isQueryingDeviceVersionsAndStorage, !ble.isQueryingAboutDeviceInfo {
                ble.queryUpgradeDeviceInfo()
            }
            return
        }

        guard let userInfo = authSession.userInfo else {
            bluetoothUpdate = nil
            firmwareUpdate = nil
            return
        }

        let lookupKeys = [deviceSN, bleUUID].filter { !$0.isEmpty }
        let bluetoothServer = lookupOTA(userInfo.bluetoothBySerialNumber, keys: lookupKeys)
        let firmwareServer = lookupOTA(userInfo.firmwareBySerialNumber, keys: lookupKeys)
        let offerKey = deviceSN.isEmpty ? bleUUID : deviceSN
        print("[DeviceOTA] keys=\(lookupKeys) bleLocal=\(bluetoothVersion) bleServer=\(bluetoothServer?.version ?? "nil") fwLocal=\(firmwareVersion) fwServer=\(firmwareServer?.version ?? "nil")")

        bluetoothUpdate = makeOffer(
            serialNumber: offerKey,
            currentVersion: bluetoothVersion,
            serverInfo: bluetoothServer
        )
        firmwareUpdate = makeOffer(
            serialNumber: offerKey,
            currentVersion: firmwareVersion,
            serverInfo: firmwareServer
        )
    }

    /// 按候选 key 查 OTA（SN 优先，UUID 兜底）；大小写不敏感。
    private func lookupOTA(_ map: [String: DeviceOTAInfo], keys: [String]) -> DeviceOTAInfo? {
        for key in keys {
            if let info = map[key] { return info }
            let upper = key.uppercased()
            for (k, v) in map where k.uppercased() == upper {
                return v
            }
        }
        return nil
    }

    private func makeOffer(
        serialNumber: String,
        currentVersion: String,
        serverInfo: DeviceOTAInfo?
    ) -> UpdateOffer? {
        guard let serverInfo else { return nil }
        let serverVersion = serverInfo.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverVersion.isEmpty else { return nil }
        // 对齐 Android UpgradeInfoManager：只有服务端版本严格更高才提示，
        // 同版本（含 V 前缀/构建后缀）及服务端旧版本均不生成升级入口。
        guard FirmwareVersionComparator.isServerVersionNewer(serverVersion, than: currentVersion) else {
            return nil
        }
        return UpdateOffer(
            serialNumber: serialNumber,
            currentVersion: currentVersion,
            serverInfo: serverInfo
        )
    }
}
