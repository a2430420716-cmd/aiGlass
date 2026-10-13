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

    /// 一代 G5K61 与二代 G5T71 共用连接管理，按 GATT 服务选择协议。
    let astraA1BleManager = AstraA1BleManager()

    weak var authSession: AuthSession? {
        didSet { observeDeviceCards() }
    }

    private var cancellables = Set<AnyCancellable>()
    private var deviceCardsObservation: AnyCancellable?
    private var hasStartedBind = false
    private var pairingAttempt = PairingAttemptState()
    private var deviceIdentityTimeout: DispatchWorkItem?
    private var pendingPairingFailureMessage: String?

    init() {
        astraA1BleManager.deviceCardPresenceProvider = { [weak self] in
            self?.hasCorrespondingDeviceCard == true
        }
        astraA1BleManager.gen1ImportAccountProvider = { [weak self] targetID, hardwareSN in
            guard let self, let auth = self.authSession, auth.isLoggedIn,
                  auth.homeDeviceCards.contains(where: { card in
                      !card.isFindDevice && DeviceAvailabilityPolicy.matches(
                          serialNumber: card.serialNumber, hardwareSN: card.hardwareSN,
                          currentPeripheralID: targetID.uuidString, currentHardwareSN: hardwareSN
                      )
                  }) else { return nil }
            return auth.userInfo.map { "user:\($0.id)" }
        }
        astraA1BleManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        astraA1BleManager.$isDeviceInfoReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard ready, let self, self.userConfirmedPairingDevice else { return }
                let token = self.pairingAttempt.generation
                Task { await self.bindDeviceIfNeeded(attempt: token) }
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
                self.cancelPairingAttempt()
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

    /// Uses the same real cards as HomeView. A find-device placeholder is never a device.
    private var hasCorrespondingDeviceCard: Bool {
        guard let authSession, authSession.isLoggedIn else { return false }
        return authSession.homeDeviceCards.contains { card in
            !card.isFindDevice && astraA1BleManager.matchesCurrentDevice(
                serialNumber: card.serialNumber, hardwareSN: card.hardwareSN
            )
        }
    }

    private func observeDeviceCards() {
        deviceCardsObservation = authSession?.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Deliver after AuthSession's @Published values change. Both BLE-observing
                // detail views and coordinator-observing home views must reevaluate the gate.
                self?.astraA1BleManager.objectWillChange.send()
                self?.objectWillChange.send()
            }
        astraA1BleManager.objectWillChange.send()
        objectWillChange.send()
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
        cancelPairingAttempt()
        selectedAPIModelName = model.modelName
        selectedEqName = model.eqName
        selectedGuideItems = guideItems
        selectedPrepareHTML = model.prepare
        pairingModel = model.glassDeviceModel
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
        pairingModel = model.glassDeviceModel
    }

    /// 配对准备页「开始配对」→ 开始蓝牙扫描/连接。
    func startPairing() {
        cancelPairingAttempt()
        hasStartedBind = false
        isBindingDevice = false
        bindStatusMessage = nil
        userConfirmedPairingDevice = false
        showSearchingSheet = true

        switch pairingModel {
        case .astraA1, .luminaL1, .unknown:
            astraA1BleManager.startPairing(preferredDeviceName: selectedAPIModelName)
        case .none:
            bindStatusMessage = L10n.t("请先选择设备型号", "Select a device model first")
            showSearchingSheet = true
        }
    }

    func pairWithDiscoveredDevice(id: UUID) {
        guard !userConfirmedPairingDevice, !isBindingDevice else { return }
        // 该眼镜已在账号里：只提示，不连接、不绑定。
        if isPeripheralAlreadyBound(id) {
            print("[Pairing] tap already-bound device \(id.uuidString), skip connect")
            pairingAlertMessage = L10n.t("设备已绑定", "Already bound")
            return
        }

        switch pairingModel {
        case .astraA1, .luminaL1, .unknown:
            if astraA1BleManager.pairWithDiscoveredDevice(id: id) {
                userConfirmedPairingDevice = true
                startDeviceIdentityTimeout(peripheralID: id)
            } else {
                pairingAlertMessage = L10n.t("配对状态已失效，请重新搜索设备", "Pairing session expired. Search again.")
            }
        case .none:
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
        case .astraA1, .luminaL1, .unknown:
            return astraA1BleManager.discoveredPairingDevices
        case .none:
            return []
        }
    }

    var isPairingSheetConnecting: Bool {
        if isBindingDevice { return true }
        if userConfirmedPairingDevice { return true }
        switch pairingModel {
        case .astraA1, .luminaL1, .unknown:
            switch astraA1BleManager.connectionState {
            case .connecting, .discoveringServices, .enablingNotifications:
                return true
            default:
                return false
            }
        case .none:
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
            case .astraA1, .luminaL1, .unknown:
                if case .failed(let message) = astraA1BleManager.connectionState {
                    return message
                }
                let status = astraA1BleManager.statusMessage
                if status.contains("系统") || status.contains("system")
                    || status.contains("读取设备信息") || status.contains("Reading device info") {
                    return status
                }
                return L10n.t("正在配对", "Pairing")
            case .none:
                return L10n.t("正在配对", "Pairing")
            }
        }
        if isPairingSheetConnecting {
            return L10n.t("正在配对", "Pairing")
        }
        switch pairingModel {
        case .astraA1, .luminaL1, .unknown:
            if case .bluetoothUnavailable(let message) = astraA1BleManager.connectionState {
                return message
            }
            return L10n.t("正在搜索设备", "Searching for devices")
        case .none:
            return L10n.t("正在搜索设备", "Searching for devices")
        }
    }

    /// 用户主动取消搜索/连接。
    func cancelSearching() {
        cancelPairingAttempt()
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
        // 等 sheet 完全退出再交给 HomeView 弹提示，避免 alert 被 sheet 遮住。
        if let message = pendingPairingFailureMessage {
            pendingPairingFailureMessage = nil
            pairingAlertMessage = message
            return
        }
        cancelPairingAttempt()
        stopActivePairingIfNeeded()
        isBindingDevice = false
        bindStatusMessage = nil
        userConfirmedPairingDevice = false
        restoreBoundDeviceConnection()
    }

    /// 配对未成功就退出时，把原本已连接的眼镜接回来（扫描/取消会断掉它）。
    func restoreBoundDeviceConnection() {
        guard !userConfirmedPairingDevice, !isBindingDevice,
              let authSession, authSession.isLoggedIn, let info = authSession.userInfo else { return }
        let serials = info.device.map(\.serialNumber)
        let ble = astraA1BleManager
        let savedIsBound = ble.savedPeripheralUUIDString.flatMap(UUID.init(uuidString:))
            .map(isPeripheralAlreadyBound) ?? false
        if !hasCorrespondingDeviceCard, (ble.isReady || (ble.savedPeripheralUUIDString != nil && !savedIsBound)) {
            DebugLogStore.logConnect("discard unbound pairing connection", detail: "reason=restore-bound-only ready=\(ble.isReady) savedIsBound=\(savedIsBound) cardCount=\(info.device.count)")
            ble.disconnectAndClearSession()
        }
        guard !serials.isEmpty else { return }
        astraA1BleManager.restoreBoundConnectionAfterPairing(boundSerialNumbers: serials)
    }

    func showNotFoundReason() {
        cancelPairingAttempt()
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
        case .astraA1, .luminaL1, .unknown:
            // GATT ready is not a completed pairing. Keep only an account device whose
            // real home card matches this connection; discard temporary pairing targets.
            if astraA1BleManager.isDeviceAvailable {
                return
            }
            DebugLogStore.logConnect("discard incomplete pairing connection", detail: "ready=\(astraA1BleManager.isReady) correspondingCard=\(hasCorrespondingDeviceCard)")
            astraA1BleManager.disconnectAndClearSession()
        case .none:
            break
        }
    }

    var searchingStatusMessage: String {
        if let bindStatusMessage {
            return bindStatusMessage
        }
        switch pairingModel {
        case .astraA1, .luminaL1, .unknown:
            return astraA1BleManager.statusMessage
        case .none:
            return L10n.t("查找设备中...", "Looking for devices...")
        }
    }

    var isSearchingInProgress: Bool {
        if isBindingDevice { return true }
        switch pairingModel {
        case .astraA1, .luminaL1, .unknown:
            switch astraA1BleManager.connectionState {
            case .ready:
                // 已连接，等待/正在绑定
                return bindStatusMessage == nil || isBindingDevice
            case .failed, .bluetoothUnavailable, .idle, .disconnected:
                return false
            default:
                return true
            }
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
        case .astraA1, .luminaL1, .unknown:
            if case .failed = astraA1BleManager.connectionState { return true }
            if case .bluetoothUnavailable = astraA1BleManager.connectionState { return true }
            return false
        case .none:
            return false
        }
    }

    func pop() {
        guard !path.isEmpty else { return }
        if userConfirmedPairingDevice || showSearchingSheet {
            cancelSearching()
        } else {
            cancelPairingAttempt()
        }
        DispatchQueue.main.async {
            self.path.removeLast()
        }
    }

    func popToRoot() {
        cancelPairingAttempt()
        let count = path.count
        guard count > 0 else { return }
        path.removeLast(count)
    }

    /// 重置账号相关配对界面。普通退登保留设备连接；账号注销才断开并清理。
    func resetForLogout(keepDeviceConnection: Bool) {
        astraA1BleManager.invalidateGen1MediaImportForLogout()
        cancelPairingAttempt()
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
    private func bindDeviceIfNeeded(attempt token: Int) async {
        guard pairingAttempt.isCurrent(token) else { return }
        guard pairingModel != nil, userConfirmedPairingDevice, !hasStartedBind else { return }
        // 保留用户选择的销售型号；不能将一代或未知型号回退成 G5T71。
        guard let bindModelName = selectedAPIModelName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bindModelName.isEmpty else { return }
        guard let request = astraA1BleManager.bindDeviceSnapshot(appModelName: bindModelName) else { return }
        guard let peripheralID = UUID(uuidString: request.serialNumber),
              pairingAttempt.beginBinding(token: token, peripheralID: peripheralID) else { return }
        cancelDeviceIdentityTimeout()

        hasStartedBind = true
        isBindingDevice = true
        bindStatusMessage = L10n.t("正在绑定设备...", "Binding device...")
        objectWillChange.send()

        print("[Pairing] bind request model_name=\(request.modelName) device_name=\(request.deviceName) sn=\(request.sn)")

        guard let authSession else {
            cancelPairingAttempt()
            isBindingDevice = false
            stopActivePairingIfNeeded()
            bindStatusMessage = L10n.t("绑定失败：未登录", "Bind failed: Not signed in")
            userConfirmedPairingDevice = false
            pairingAlertMessage = bindStatusMessage
            return
        }

        // 当前账号已绑定同一设备：提示后断开，不重复绑，保留 sheet 让用户看到提示。
        if isDeviceAlreadyBoundToCurrentAccount(request) {
            cancelPairingAttempt()
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
            guard pairingAttempt.isCurrent(token) else { return }
            isBindingDevice = false
            bindStatusMessage = L10n.t("绑定成功", "Bound successfully")
            objectWillChange.send()

            try? await Task.sleep(nanoseconds: 800_000_000)
            guard pairingAttempt.isCurrent(token) else { return }
            userConfirmedPairingDevice = false
            popToRoot()
            checkClassicAudioConnectedAfterPairing()
        } catch {
            guard pairingAttempt.isCurrent(token) else { return }
            cancelPairingAttempt()
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
                stopActivePairingIfNeeded()
            }
            userConfirmedPairingDevice = false
            pairingAlertMessage = bindStatusMessage
            objectWillChange.send()
        }
    }

    /// Match Android's 60-second device-info deadline after the user selects a device.
    private func startDeviceIdentityTimeout(peripheralID: UUID) {
        cancelDeviceIdentityTimeout()
        pendingPairingFailureMessage = nil
        let token = pairingAttempt.begin(peripheralID: peripheralID)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pairingAttempt.expireIdentityWait(token: token) else { return }
            self.deviceIdentityTimeout = nil
            self.userConfirmedPairingDevice = false
            self.isBindingDevice = false
            self.hasStartedBind = false
            let message = L10n.t(
                "配对失败：未能读取完整设备信息，请重新搜索并配对。",
                "Pairing failed: Could not read complete device information. Search and pair again."
            )
            self.bindStatusMessage = message
            DebugLogStore.logConnect("pairing identity timeout", detail: "timeout=60s peripheral=\(peripheralID.uuidString) ready=\(self.astraA1BleManager.isReady) hasCompleteIdentity=\(self.astraA1BleManager.isDeviceInfoReady); attempt invalidated, late identity cannot bind")

            // A stale deadline must never disconnect another or already-bound device.
            let currentID = self.astraA1BleManager.deviceBluetoothIdentifier
            let savedID = self.astraA1BleManager.savedPeripheralUUIDString
            let stillTargetsAttempt = currentID == peripheralID.uuidString
                || (currentID == nil && savedID == peripheralID.uuidString)
            if stillTargetsAttempt,
               !self.isPeripheralAlreadyBound(peripheralID) {
                // READY saves this temporary target before server binding. Clear it
                // so restoring an older binding cannot reconnect the timed-out target.
                self.astraA1BleManager.disconnectAndClearSession()
            }
            if self.showSearchingSheet {
                self.pendingPairingFailureMessage = message
                self.showSearchingSheet = false
            } else {
                self.pairingAlertMessage = message
            }
            self.restoreBoundDeviceConnection()
        }
        deviceIdentityTimeout = timeout
        DebugLogStore.logConnect("pairing identity wait started", detail: "timeout=60s peripheral=\(peripheralID.uuidString) attempt=\(token)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
    }

    private func cancelDeviceIdentityTimeout() {
        deviceIdentityTimeout?.cancel()
        deviceIdentityTimeout = nil
    }

    private func cancelPairingAttempt() {
        if pairingAttempt.phase != .idle {
            DebugLogStore.logConnect("pairing attempt invalidated", detail: "attempt=\(pairingAttempt.generation) phase=\(pairingAttempt.phase) target=\(pairingAttempt.peripheralID?.uuidString ?? "nil") ready=\(astraA1BleManager.isReady) correspondingCard=\(hasCorrespondingDeviceCard)")
        }
        cancelDeviceIdentityTimeout()
        pairingAttempt.cancel()
        pendingPairingFailureMessage = nil
        userConfirmedPairingDevice = false
    }

    /// iOS 无公开 API 主动发起经典蓝牙连接，A2DP/AVRCP 只能由眼镜或系统设置建立。
    /// 绑定后经典蓝牙没起来时，媒体键（上一首/下一首）和音量都不会生效，这里提示用户手动连一次。
    private func checkClassicAudioConnectedAfterPairing() {
        let generation = pairingAttempt.generation
        Task { @MainActor in
            // 经典蓝牙常比 BLE 晚几秒，给足重试窗口再判定。
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard pairingAttempt.generation == generation else { return }
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
