import Combine
import SwiftUI

enum PairingDestination: Hashable {
    case device
    case preparation
    case selectDevice
    case notFoundReason
}

@MainActor
final class PairingCoordinator: ObservableObject {
    @Published var path: [PairingDestination] = []
    @Published var showSearchingSheet = false
    @Published private(set) var pairingModel: GlassDeviceModel?
    @Published private(set) var selectedAPIModelName: String?
    @Published private(set) var selectedEqName: String?
    @Published private(set) var selectedGuideItems: [DeviceGuideItem] = []
    @Published private(set) var selectedPrepareHTML: String?
    @Published private(set) var isBindingDevice = false
    @Published private(set) var bindStatusMessage: String?
    /// 用户已在列表中点「配对」后锁定弹窗为加载态，直到成功或失败。
    @Published private(set) var userConfirmedPairingDevice = false
    /// 配对列表点选后的即时提示（如设备已绑定）。
    @Published var pairingAlertMessage: String?
    /// 绑定成功但经典蓝牙（A2DP/AVRCP）未连上时的引导提示。
    @Published var classicAudioTipMessage: String?

    /// Astra A1 / G5T71：BLE 连接（CYT 文档协议）
    let astraA1BleManager = AstraA1BleManager()
    /// Lumina L1：连接方式不同，后续单独实现
    let luminaL1Connector = LuminaL1Connector()

    weak var authSession: AuthSession?

    private var cancellables = Set<AnyCancellable>()
    private var hasStartedBind = false

    init() {
        astraA1BleManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        luminaL1Connector.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        astraA1BleManager.$isDeviceInfoReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard ready else { return }
                Task { await self?.bindAstraDeviceIfNeeded() }
            }
            .store(in: &cancellables)

        astraA1BleManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.userConfirmedPairingDevice else { return }
                let message: String?
                switch state {
                case .failed(let value), .bluetoothUnavailable(let value):
                    message = value
                default:
                    message = nil
                }
                guard let message else { return }
                self.userConfirmedPairingDevice = false
                self.isBindingDevice = false
                self.hasStartedBind = false
                self.bindStatusMessage = nil
                self.pairingAlertMessage = message
                self.restoreBoundDeviceConnection()
            }
            .store(in: &cancellables)

        // 用户点列表中的「配对」后，底部弹框继续展示连接进度；只有 BLE 已就绪、
        // iOS 系统配对请求真正进入等待阶段时才收起，避免搜索列表阶段过早消失。
        astraA1BleManager.$statusMessage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self,
                      self.userConfirmedPairingDevice,
                      message.contains("系统弹窗")
                        || message.localizedCaseInsensitiveContains("system alert") else {
                    return
                }
                self.showSearchingSheet = false
            }
            .store(in: &cancellables)
    }

    func openPairingFlow() {
        guard path.isEmpty else { return }
        path.append(PairingDestination.selectDevice)
    }

    /// 选择设备后 → 去配对页。
    func goToPairDevice() {
        DispatchQueue.main.async {
            self.path.append(PairingDestination.device)
        }
    }

    /// 去配对页「去配对」→ 配对准备页。
    func goToPreparation() {
        DispatchQueue.main.async {
            self.path.append(PairingDestination.preparation)
        }
    }

    /// 记录所选型号信息，直接进入配对准备页。对齐 Android，删除多余「去配对」中间页。
    func selectDevice(_ model: DeviceModelItem, guideItems: [DeviceGuideItem]) {
        selectedAPIModelName = model.modelName
        selectedEqName = model.eqName
        selectedGuideItems = guideItems
        selectedPrepareHTML = model.prepare
        pairingModel = model.usesAstraBLE ? .astraA1 : .luminaL1
        hasStartedBind = false
        isBindingDevice = false
        bindStatusMessage = nil

        print("[Pairing] selected eq_name=\(model.eqName) model_name=\(model.modelName) guide_count=\(guideItems.count)")

        goToPreparation()
    }

    /// 单型号接口返回后刷新 prepare；只接受当前所选型号，避免快速切换时旧请求串页。
    func refreshSelectedDeviceModel(_ model: DeviceModelItem) {
        guard selectedAPIModelName == model.modelName else { return }
        selectedEqName = model.eqName
        selectedPrepareHTML = model.prepare
        pairingModel = model.usesAstraBLE ? .astraA1 : .luminaL1
    }

    /// 配对准备页「开始配对」→ 开始蓝牙扫描/连接。
    func startPairing() {
        hasStartedBind = false
        isBindingDevice = false
        bindStatusMessage = nil
        userConfirmedPairingDevice = false
        showSearchingSheet = true

        switch pairingModel {
        case .astraA1:
            astraA1BleManager.startPairing(preferredDeviceName: selectedAPIModelName)
        case .luminaL1:
            luminaL1Connector.startPairing()
        case .none:
            bindStatusMessage = L10n.t("请先选择设备型号", "Select a device model first")
            showSearchingSheet = true
        }
    }

    func pairWithDiscoveredDevice(id: UUID) {
        // 该眼镜已在账号里：只提示，不连接、不绑定。
        if isPeripheralAlreadyBound(id) {
            print("[Pairing] tap already-bound device \(id.uuidString), skip connect")
            pairingAlertMessage = L10n.t("设备已绑定", "Already bound")
            return
        }

        switch pairingModel {
        case .astraA1:
            if astraA1BleManager.pairWithDiscoveredDevice(id: id) {
                userConfirmedPairingDevice = true
            } else {
                pairingAlertMessage = L10n.t("配对状态已失效，请重新搜索设备", "Pairing session expired. Search again.")
            }
        case .luminaL1, .none:
            break
        }
    }

    /// iOS 上绑定的 `serial_number` 就是外设 UUID，可直接与扫描结果比对。
    private func isPeripheralAlreadyBound(_ id: UUID) -> Bool {
        let uuid = id.uuidString
        let devices = authSession?.userInfo?.device ?? []
        return devices.contains { device in
            let serial = device.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            return !serial.isEmpty && serial.caseInsensitiveCompare(uuid) == .orderedSame
        }
    }

    var discoveredPairingDevices: [DiscoveredBLEDevice] {
        switch pairingModel {
        case .astraA1:
            return astraA1BleManager.discoveredPairingDevices
        case .luminaL1, .none:
            return []
        }
    }

    var isPairingSheetConnecting: Bool {
        if isBindingDevice { return true }
        if userConfirmedPairingDevice { return true }
        switch pairingModel {
        case .astraA1:
            switch astraA1BleManager.connectionState {
            case .connecting, .discoveringServices, .enablingNotifications:
                return true
            default:
                return false
            }
        case .luminaL1, .none:
            return false
        }
    }

    var pairingSheetLoadingText: String {
        if isBindingDevice {
            return L10n.t("正在绑定设备...", "Binding device...")
        }
        if userConfirmedPairingDevice {
            if let bindStatusMessage, isBindFailureOrAlreadyBound(bindStatusMessage) {
                return bindStatusMessage
            }
            switch pairingModel {
            case .astraA1:
                if case .failed(let message) = astraA1BleManager.connectionState {
                    return message
                }
                let status = astraA1BleManager.statusMessage
                if status.contains("系统") || status.contains("system")
                    || status.contains("读取设备信息") || status.contains("Reading device info") {
                    return status
                }
                return L10n.t("正在配对", "Pairing")
            case .luminaL1, .none:
                return L10n.t("正在配对", "Pairing")
            }
        }
        if isPairingSheetConnecting {
            return L10n.t("正在配对", "Pairing")
        }
        switch pairingModel {
        case .astraA1:
            if case .bluetoothUnavailable(let message) = astraA1BleManager.connectionState {
                return message
            }
            return L10n.t("正在搜索设备", "Searching for devices")
        case .luminaL1:
            return luminaL1Connector.statusMessage
        case .none:
            return L10n.t("正在搜索设备", "Searching for devices")
        }
    }

    /// 用户主动取消搜索/连接。
    func cancelSearching() {
        stopActivePairingIfNeeded()
        isBindingDevice = false
        bindStatusMessage = nil
        hasStartedBind = false
        userConfirmedPairingDevice = false
        showSearchingSheet = false
        restoreBoundDeviceConnection()
    }

    /// sheet 关闭时回调：连接成功则保留 BLE，否则停止扫描。
    func onSearchingSheetDismissed() {
        // 用户点「配对」后的程序化关闭：BLE 流程继续，不能当成取消。
        if userConfirmedPairingDevice { return }
        stopActivePairingIfNeeded()
        isBindingDevice = false
        bindStatusMessage = nil
        userConfirmedPairingDevice = false
        restoreBoundDeviceConnection()
    }

    /// 配对未成功就退出时，把原本已连接的眼镜接回来（扫描/取消会断掉它）。
    func restoreBoundDeviceConnection() {
        let serials = (authSession?.userInfo?.device ?? []).map(\.serialNumber)
        astraA1BleManager.restoreBoundConnectionAfterPairing(boundSerialNumbers: serials)
    }

    func showNotFoundReason() {
        stopActivePairingIfNeeded()
        isBindingDevice = false
        bindStatusMessage = nil
        hasStartedBind = false
        userConfirmedPairingDevice = false
        showSearchingSheet = false
        DispatchQueue.main.async {
            self.path.append(PairingDestination.notFoundReason)
        }
    }

    private func stopActivePairingIfNeeded() {
        switch pairingModel {
        case .astraA1:
            // 已连接成功时保留 BLE，仅停止未完成的扫描/连接
            if case .ready = astraA1BleManager.connectionState {
                return
            }
            astraA1BleManager.cancelPairing()
        case .luminaL1:
            luminaL1Connector.cancelPairing()
        case .none:
            break
        }
    }

    var searchingStatusMessage: String {
        if let bindStatusMessage {
            return bindStatusMessage
        }
        switch pairingModel {
        case .astraA1:
            return astraA1BleManager.statusMessage
        case .luminaL1:
            return luminaL1Connector.statusMessage
        case .none:
            return L10n.t("查找设备中...", "Looking for devices...")
        }
    }

    var isSearchingInProgress: Bool {
        if isBindingDevice { return true }
        switch pairingModel {
        case .astraA1:
            switch astraA1BleManager.connectionState {
            case .ready:
                // 已连接，等待/正在绑定
                return bindStatusMessage == nil || isBindingDevice
            case .failed, .bluetoothUnavailable, .idle, .disconnected:
                return false
            default:
                return true
            }
        case .luminaL1:
            return false
        case .none:
            return true
        }
    }

    var didPairingFail: Bool {
        if let bindStatusMessage, !isBindingDevice,
           isBindFailureOrAlreadyBound(bindStatusMessage) {
            return true
        }
        switch pairingModel {
        case .astraA1:
            if case .failed = astraA1BleManager.connectionState { return true }
            if case .bluetoothUnavailable = astraA1BleManager.connectionState { return true }
            return false
        case .luminaL1:
            return true
        case .none:
            return false
        }
    }

    func pop() {
        guard !path.isEmpty else { return }
        DispatchQueue.main.async {
            self.path.removeLast()
        }
    }

    func popToRoot() {
        let count = path.count
        guard count > 0 else { return }
        path.removeLast(count)
    }

    /// 重置账号相关配对界面。普通退登保留设备连接；账号注销才断开并清理。
    func resetForLogout(keepDeviceConnection: Bool) {
        showSearchingSheet = false
        isBindingDevice = false
        bindStatusMessage = nil
        hasStartedBind = false
        pairingModel = nil
        selectedAPIModelName = nil
        selectedEqName = nil
        selectedGuideItems = []
        selectedPrepareHTML = nil
        path.removeAll()
        if !keepDeviceConnection {
            astraA1BleManager.disconnectAndClearSession()
            luminaL1Connector.cancelPairing()
        }
    }

    /// 解除配对：调用解绑接口，断开 BLE 并清除本地连接记录。
    /// - Parameters:
    ///   - serialNumber: 蓝牙标识（`serial_number`）
    ///   - sn: 设备硬件 SN（`sn`）
    func unpairDevice(serialNumber: String, sn: String) async throws {
        guard let authSession else {
            throw APIError.server(message: L10n.t("未登录", "Not signed in"), code: -1)
        }

        let targetSerial = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetSN = sn.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveIdentifiers = [
            astraA1BleManager.deviceBluetoothIdentifier,
            astraA1BleManager.savedPeripheralUUIDString
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let liveSN = astraA1BleManager.deviceSN?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isCurrentDevice = liveIdentifiers.contains {
            $0.caseInsensitiveCompare(targetSerial) == .orderedSame
        } || (liveSN?.caseInsensitiveCompare(targetSN) == .orderedSame)

        try await authSession.unbindDevice(serialNumber: serialNumber, sn: sn)
        astraA1BleManager.forgetCachedHardwareSN(forSerialNumber: serialNumber)

        if isCurrentDevice {
            astraA1BleManager.disconnectAndClearSession()
            let remainingSerials = (authSession.userInfo?.device ?? []).map(\.serialNumber)
            astraA1BleManager.restoreBoundConnectionAfterPairing(
                boundSerialNumbers: remainingSerials
            )
        }

        print("[Pairing] unpair completed serial_number=\(serialNumber) sn=\(sn) current=\(isCurrentDevice)")
    }

    /// 当前账号绑定的主设备序列号（用于解绑 `serial_number`）。
    var boundDeviceSerialNumber: String? {
        authSession?.userInfo?.device.first?.serialNumber
    }

    /// 当前账号绑定的主设备硬件 SN（用于解绑 `sn`）。
    /// 眼镜断连后实时 SN 会被清空，依次回退到本地缓存与 userinfo 返回值。
    var boundDeviceHardwareSN: String? {
        if let live = astraA1BleManager.deviceSN?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !live.isEmpty {
            return live
        }
        if let cached = astraA1BleManager.cachedHardwareSN(forSerialNumber: boundDeviceSerialNumber) {
            return cached
        }
        guard let stored = authSession?.userInfo?.device.first?.hardwareSN?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty else {
            return nil
        }
        return stored
    }

    /// BLE 读到设备信息后：绑定设备 → 刷新用户信息 → 回首页。
    private func bindAstraDeviceIfNeeded() async {
        guard pairingModel == .astraA1, userConfirmedPairingDevice, !hasStartedBind else { return }
        // model_name 必须用接口型号列表里的名称（如 G5T71），不能用 BLE 硬件码 MCA010
        let bindModelName = selectedAPIModelName ?? "G5T71"
        guard let request = astraA1BleManager.bindDeviceSnapshot(appModelName: bindModelName) else { return }

        hasStartedBind = true
        isBindingDevice = true
        bindStatusMessage = L10n.t("正在绑定设备...", "Binding device...")
        objectWillChange.send()

        print("[Pairing] bind request model_name=\(request.modelName) device_name=\(request.deviceName) sn=\(request.sn)")

        guard let authSession else {
            isBindingDevice = false
            bindStatusMessage = L10n.t("绑定失败：未登录", "Bind failed: Not signed in")
            userConfirmedPairingDevice = false
            pairingAlertMessage = bindStatusMessage
            return
        }

        // 当前账号已绑定同一设备：提示后断开，不重复绑，保留 sheet 让用户看到提示。
        if isDeviceAlreadyBoundToCurrentAccount(request) {
            isBindingDevice = false
            bindStatusMessage = L10n.t("设备已绑定", "Already bound")
            objectWillChange.send()
            print("[Pairing] device already bound to current account, disconnect without rebind sn=\(request.sn)")
            astraA1BleManager.disconnectAndClearSession()
            userConfirmedPairingDevice = false
            pairingAlertMessage = bindStatusMessage
            return
        }

        do {
            try await authSession.bindDeviceAndRefresh(request)
            isBindingDevice = false
            bindStatusMessage = L10n.t("绑定成功", "Bound successfully")
            objectWillChange.send()

            try? await Task.sleep(nanoseconds: 800_000_000)
            userConfirmedPairingDevice = false
            popToRoot()
            checkClassicAudioConnectedAfterPairing()
        } catch {
            isBindingDevice = false
            let message = error.localizedDescription
            // 已绑定其他账号：提示后断开，不做解绑/重绑。
            if AuthSession.isDeviceAlreadyBoundError(error) {
                bindStatusMessage = message.isEmpty ? L10n.t("设备已绑定", "Already bound") : message
                print("[Pairing] device already bound, disconnect without retry: \(bindStatusMessage ?? "")")
                astraA1BleManager.disconnectAndClearSession()
            } else {
                bindStatusMessage = L10n.t("绑定失败：\(message)", "Bind failed: \(message)")
                print("[Pairing] bind failed: \(message)")
            }
            userConfirmedPairingDevice = false
            pairingAlertMessage = bindStatusMessage
            objectWillChange.send()
        }
    }

    /// iOS 无公开 API 主动发起经典蓝牙连接，A2DP/AVRCP 只能由眼镜或系统设置建立。
    /// 绑定后经典蓝牙没起来时，媒体键（上一首/下一首）和音量都不会生效，这里提示用户手动连一次。
    private func checkClassicAudioConnectedAfterPairing() {
        Task { @MainActor in
            // 经典蓝牙常比 BLE 晚几秒，给足重试窗口再判定。
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard astraA1BleManager.isReady, !GlassesAudioRouteController.isOutputOnBluetooth else { return }
            print("[Pairing] classic bluetooth audio not connected after pairing")
            classicAudioTipMessage = L10n.t(
                "眼镜的蓝牙音频未连接，暂时无法用触控板控制音乐播放和音量。请到「设置 > 蓝牙」中连接这副眼镜。",
                "Bluetooth audio is not connected. Touchpad music and volume controls won't work until you connect these glasses in Settings > Bluetooth."
            )
        }
    }

    private func isBindFailureOrAlreadyBound(_ message: String) -> Bool {
        message.contains("失败")
            || message.localizedCaseInsensitiveContains("failed")
            || message.contains("已绑定")
            || message.localizedCaseInsensitiveContains("already bound")
    }
    private func isDeviceAlreadyBoundToCurrentAccount(_ request: BindDeviceRequest) -> Bool {
        let devices = authSession?.userInfo?.device ?? []
        let serial = request.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let sn = request.sn.trimmingCharacters(in: .whitespacesAndNewlines)
        return devices.contains { device in
            let deviceSerial = device.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceSN = device.hardwareSN?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !serial.isEmpty, !deviceSerial.isEmpty,
               serial.caseInsensitiveCompare(deviceSerial) == .orderedSame {
                return true
            }
            if !sn.isEmpty, !deviceSN.isEmpty,
               sn.caseInsensitiveCompare(deviceSN) == .orderedSame {
                return true
            }
            return false
        }
    }
}
