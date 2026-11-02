import SwiftUI

struct DeviceCardData: Identifiable, Equatable {
    let id: String
    let name: String?
    let modelName: String?
    /// 品牌名，对齐 Android 首页卡片 `tv_eq_name`，缺省显示 MOCO。
    let eqName: String?
    /// 账号绑定 serial_number（iOS 为 BLE UUID）。
    let serialNumber: String?
    /// 硬件 SN（若 userinfo 有返回）。
    let hardwareSN: String?
    let batteryPercent: Int?
    let imageName: String
    let isFindDevice: Bool
    let isCharging: Bool
    let isConnected: Bool

    static let findDevice = DeviceCardData(
        id: "find-device",
        name: nil,
        modelName: nil,
        serialNumber: nil,
        hardwareSN: nil,
        batteryPercent: nil,
        imageName: "glass2",
        isFindDevice: true
    )

    init(
        id: String,
        name: String?,
        modelName: String?,
        eqName: String? = nil,
        serialNumber: String? = nil,
        hardwareSN: String? = nil,
        batteryPercent: Int?,
        imageName: String,
        isFindDevice: Bool,
        isCharging: Bool = false,
        isConnected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.modelName = modelName
        self.eqName = eqName
        self.serialNumber = serialNumber
        self.hardwareSN = hardwareSN
        self.batteryPercent = batteryPercent
        self.imageName = imageName
        self.isFindDevice = isFindDevice
        self.isCharging = isCharging
        self.isConnected = isConnected
    }

    init(device: UserDevice) {
        id = "device-\(device.id ?? 0)-\(device.serialNumber)"
        name = device.displayName
        modelName = device.modelName
        eqName = device.eqName
        serialNumber = device.serialNumber
        hardwareSN = device.hardwareSN
        batteryPercent = nil
        imageName = device.cardImageName
        isFindDevice = false
        isCharging = false
        isConnected = false
    }

    func withConnection(isConnected: Bool, batteryPercent: Int?, isCharging: Bool,
                        connectedImageName: String? = nil) -> DeviceCardData {
        DeviceCardData(
            id: id,
            name: name,
            modelName: modelName,
            eqName: eqName,
            serialNumber: serialNumber,
            hardwareSN: hardwareSN,
            batteryPercent: isConnected ? batteryPercent : nil,
            imageName: isConnected ? (connectedImageName ?? imageName) : imageName,
            isFindDevice: isFindDevice,
            isCharging: isConnected ? isCharging : false,
            isConnected: isConnected
        )
    }

    func withDisplayName(_ displayName: String?) -> DeviceCardData {
        DeviceCardData(
            id: id,
            name: displayName,
            modelName: modelName,
            eqName: eqName,
            serialNumber: serialNumber,
            hardwareSN: hardwareSN,
            batteryPercent: batteryPercent,
            imageName: imageName,
            isFindDevice: isFindDevice,
            isCharging: isCharging,
            isConnected: isConnected
        )
    }
}

/// 用户自定义首页设备名。按设备序列号保存，避免多副眼镜串名。
enum DeviceDisplayNameStore {
    private static let defaultsKey = "home.device.customDisplayNames.v1"

    static func displayName(for device: DeviceCardData) -> String? {
        guard let key = deviceKey(for: device) else { return nil }
        let value = storedNames()[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static func save(_ name: String, for device: DeviceCardData) {
        guard let key = deviceKey(for: device) else { return }
        var names = storedNames()
        names[key] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(names, forKey: defaultsKey)
    }

    static func remove(serialNumber: String) {
        var names = storedNames()
        names.removeValue(forKey: "serial:\(serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())")
        UserDefaults.standard.set(names, forKey: defaultsKey)
    }

    private static func storedNames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private static func deviceKey(for device: DeviceCardData) -> String? {
        let serial = device.serialNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !serial.isEmpty {
            return "serial:\(serial.lowercased())"
        }
        return device.isFindDevice ? nil : "id:\(device.id.lowercased())"
    }
}

struct HomeView: View {
    @Binding var showsTabBar: Bool

    private var selectedDeviceIndex: Int {
        get {
            let cards = homeDeviceCards
            if let key = authSession.selectedHomeDeviceKey,
               let index = cards.firstIndex(where: {
                   ($0.serialNumber ?? $0.id).caseInsensitiveCompare(key) == .orderedSame
               }) {
                return index
            }
            if let saved = ble.savedPeripheralUUIDString,
               let index = cards.firstIndex(where: { $0.serialNumber?.caseInsensitiveCompare(saved) == .orderedSame }) {
                return index
            }
            return cards.firstIndex(where: {
                !$0.isFindDevice && ble.isReady && ble.matchesCurrentDevice(serialNumber: $0.serialNumber, hardwareSN: $0.hardwareSN)
            }) ?? 0
        }
        nonmutating set {
            guard canManageHomeConnection else { return }
            let cards = homeDeviceCards
            guard cards.indices.contains(newValue) else { return }
            let card = cards[newValue]
            if !card.isFindDevice, card.serialNumber?.caseInsensitiveCompare(ble.savedPeripheralUUIDString ?? "") != .orderedSame,
               isHomeDeviceSwitchBusy {
                mediaActionAlertMessage = L10n.t("眼镜正在执行任务，请结束后再切换设备", "The glasses are busy. Finish the current task before switching devices.")
                return
            }
            let key = card.serialNumber ?? card.id
            if authSession.selectedHomeDeviceKey != key {
                DebugLogStore.logConnect("home card user selection", detail: "previous=\(authSession.selectedHomeDeviceKey ?? "nil") selected=\(key) source=carouselGesture ready=\(ble.isReady)")
                authSession.selectedHomeDeviceKey = key
            }
        }
    }
    @ObservedObject private var systemVolume = SystemVolumeController.shared
    @State private var showSoundEffectSheet = false
    @State private var homeIsVisible = false
    @State private var tabBarSuppressionCount = 0
    @State private var mediaActionAlertMessage: String?
    @State private var mediaActionToastMessage: String?
    @State private var mediaActionToastID = UUID()
    @State private var navigateToNewbieGuide = false
    @State private var navigateToOperationGuide = false
    @State private var navigateToGlassesSettings = false
    @State private var settingsDevice: DeviceCardData?
    @State private var editingDevice: DeviceCardData?
    @State private var deviceNameRevision = 0
    @State private var navigateToAIRecording = false
    @State private var navigateToAITranslation = false
    /// 点卡片手动重连中的设备（搜索 → 连接期间禁止重复点击）。
    @State private var reconnectingDeviceID: String?
    /// 重连失败结果：卡片恢复可点，文案提示未找到 / 连接失败。
    @State private var reconnectFailure: DeviceReconnectFailure?
    /// 用户主动点击硬重连后仍失败，提示重启眼镜与手机系统蓝牙。
    @State private var showHardReconnectFailureAlert = false
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var pairingCoordinator: PairingCoordinator
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var tabRouter: MainTabRouter
    @EnvironmentObject private var aiVisionTransfer: AiVisionTransferManager
    @EnvironmentObject private var importManager: MediaImportManager
    @EnvironmentObject private var recordingImportManager: AIRecordingImportManager

    private var ble: AstraA1BleManager {
        pairingCoordinator.astraA1BleManager
    }

    private func showsCapability(_ capability: KeyPath<DeviceCapabilities, Bool>) -> Bool {
        ble.deviceGeneration == .unknown || ble.deviceCapabilities[keyPath: capability]
    }

    private var selectedSoundMode: SoundEffectMode {
        SoundEffectMode(rawValue: ble.soundEffectMode) ?? .standard
    }

    /// 读取本地自定义名；revision 仅用于保存后立即触发 SwiftUI 重算。
    private var homeDeviceCards: [DeviceCardData] {
        _ = deviceNameRevision
        return authSession.homeDeviceCards.map { card in
            guard !card.isFindDevice else { return card }
            if let customName = DeviceDisplayNameStore.displayName(for: card) {
                return card.withDisplayName(customName)
            }
            if ble.matchesCurrentDevice(serialNumber: card.serialNumber, hardwareSN: card.hardwareSN),
               let name = [ble.deviceName, ble.currentPeripheralName]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                return card.withDisplayName(name)
            }
            return card
        }
    }

    private var homeBoundDeviceIdentities: [String] {
        authSession.homeDeviceCards.filter { !$0.isFindDevice }.map {
            "\($0.serialNumber ?? $0.id)|\($0.hardwareSN ?? "")"
        }
    }

    /// 当前首页选中设备型号，供引导/操作指南接口使用。
    private var currentGuideModelName: String {
        let cards = homeDeviceCards
        if selectedDeviceIndex < cards.count,
           let model = cards[selectedDeviceIndex].modelName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            return model
        }
        if let model = authSession.userInfo?.device.first?.modelName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            return model
        }
        return pairingCoordinator.selectedAPIModelName
            ?? (ble.deviceGeneration == .gen1G5K61 ? "G5K61" : "G5T71")
    }

    var body: some View {
        CompatibleNavigationStackPath(path: $pairingCoordinator.path) {
            scrollContent
                .mainTabRootContent()
                .background {
                    GeometryReader { proxy in
                        Image("bg")
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    }
                    .ignoresSafeArea()
                }
                .sheet(isPresented: $showSoundEffectSheet) {
                    SoundEffectModeSheet(
                        selectedMode: selectedSoundMode,
                        onSelect: { mode in
                            _ = ble.setSoundEffectMode(mode.rawValue)
                        }
                    )
                        .compatiblePresentationDetents([.height(300)])
                        .compatiblePresentationDragIndicator(.hidden)
                        .compatiblePresentationCornerRadius(32)
                        .compatiblePresentationBackground(AppTheme.cardBackground)
                }
                .sheet(item: $editingDevice) { device in
                    DeviceNameEditSheet(currentName: device.name ?? "") { newName in
                        DeviceDisplayNameStore.save(newName, for: device)
                        deviceNameRevision += 1
                    }
                    .compatiblePresentationDetents([.height(270)])
                    .compatiblePresentationDragIndicator(.hidden)
                    .compatiblePresentationCornerRadius(32)
                    .compatiblePresentationBackground(AppTheme.cardBackground)
                }
        } destination: { destination in
            pairingScreen {
                switch destination {
                case .device:
                    PairDeviceView {
                        pairingCoordinator.pop()
                    }
                    .environmentObject(pairingCoordinator)
                case .preparation:
                    pairingPreparationScreen {
                        pairingCoordinator.pop()
                    }
                case .selectDevice:
                    DeviceSelectionView {
                        pairingCoordinator.pop()
                    }
                    .environmentObject(pairingCoordinator)
                case .notFoundReason:
                    PairingNotFoundReasonView {
                        pairingCoordinator.pop()
                    }
                    .environmentObject(pairingCoordinator)
                }
            }
        }
        .id(pairingCoordinator.navigationResetID)
        .environment(\.tabBarSuppressionCount, $tabBarSuppressionCount)
        .background(tabRouter.navigationBackdropColor.ignoresSafeArea())
        .compatibleNavigationContainerBackground(tabRouter.navigationBackdropColor)
        .navigationControllerBackground(tabRouter.navigationBackdropColor)
        .animation(.none, value: tabRouter.usesBlackNavigationBackdrop)
        .sheet(isPresented: $pairingCoordinator.showSearchingSheet, onDismiss: {
            pairingCoordinator.onSearchingSheetDismissed()
        }) {
            DeviceSearchingSheet(
                devices: pairingCoordinator.discoveredPairingDevices,
                loadingText: pairingCoordinator.pairingSheetLoadingText,
                isConnecting: pairingCoordinator.isPairingSheetConnecting,
                isBinding: pairingCoordinator.isBindingDevice,
                onPair: { pairingCoordinator.pairWithDiscoveredDevice(id: $0) },
                onCancel: { pairingCoordinator.cancelSearching() }
            )
            .onAppear { pairingCoordinator.onSearchingSheetPresented() }
            .compatiblePresentationDragIndicator(.hidden)
            .compatiblePresentationCornerRadius(32)
            .compatiblePresentationBackground(AppTheme.cardBackground)
        }
        .onChangeCompat(of: pairingCoordinator.path.count) { count in
            updateTabBarVisibility()
            // 退出配对流程：把配对扫描期间被断开的已绑定眼镜接回来。
            if count == 0 {
                pairingCoordinator.restoreBoundDeviceConnection()
            }
        }
        .onChangeCompat(of: ble.mediaActionAlertMessage) { message in
            guard let message, !message.isEmpty else { return }
            if isDeviceBusyMessage(message) {
                showMediaActionToast(message)
            } else {
                mediaActionAlertMessage = message
            }
            ble.mediaActionAlertMessage = nil
        }
        .onChangeCompat(of: ble.mediaActionToastMessage) { message in
            guard let message, !message.isEmpty else { return }
            showMediaActionToast(message)
            ble.mediaActionToastMessage = nil
        }
        .onChangeCompat(of: pairingCoordinator.pairingAlertMessage) { message in
            guard let message, !message.isEmpty else { return }
            mediaActionAlertMessage = message
            pairingCoordinator.pairingAlertMessage = nil
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { mediaActionAlertMessage != nil },
            set: { if !$0 { mediaActionAlertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(mediaActionAlertMessage ?? "")
        }
        .alert(
            L10n.t("连接失败", "Connection Failed"),
            isPresented: $showHardReconnectFailureAlert
        ) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(L10n.t(
                "连接仍然失败。请重启眼镜，并关闭后重新打开手机系统蓝牙，然后再点击重试。",
                "Connection still failed. Restart the glasses, turn system Bluetooth off and back on, then tap Retry again."
            ))
        }
        .alert(L10n.t("蓝牙音频未连接", "Bluetooth Audio Not Connected"), isPresented: Binding(
            get: { pairingCoordinator.classicAudioTipMessage != nil },
            set: { if !$0 { pairingCoordinator.classicAudioTipMessage = nil } }
        )) {
            Button(L10n.t("知道了", "Got It"), role: .cancel) {}
        } message: {
            Text(pairingCoordinator.classicAudioTipMessage ?? "")
        }
        .onChangeCompat(of: tabBarSuppressionCount) { _ in
            updateTabBarVisibility()
        }
        .onChangeCompat(of: navigateToNewbieGuide) { active in
            if !active {
                tabRouter.endImmersiveCover()
                tabRouter.setBlackNavigationBackdrop(false)
            }
        }
        .onChangeCompat(of: navigateToOperationGuide) { active in
            if !active { tabRouter.endImmersiveCover() }
        }
        .onChangeCompat(of: navigateToGlassesSettings) { active in
            if !active { tabRouter.endImmersiveCover() }
            updateTabBarVisibility()
        }
        .onChangeCompat(of: navigateToAIRecording) { active in
            if !active { tabRouter.endImmersiveCover() }
        }
        .onChangeCompat(of: navigateToAITranslation) { active in
            if !active { tabRouter.endImmersiveCover() }
        }
        .onAppear {
            homeIsVisible = true
            synchronizeConnectedHomeCard(reason: "home-appear")
            systemVolume.refresh()
            systemVolume.beginPollingWhileVisible()
            Task { await reloadHomeDeviceState() }
        }
        .onDisappear {
            homeIsVisible = false
            systemVolume.endPollingWhileVisible()
        }
        .onViewWillAppear {
            synchronizeConnectedHomeCard(reason: "home-will-appear")
            systemVolume.refresh()
        }
        .onChangeCompat(of: ble.isReady) { ready in
            if ready, canManageHomeConnection {
                synchronizeConnectedHomeCard(reason: "ble-ready")
            }
        }
        .onChangeCompat(of: canManageHomeConnection) { active in
            DebugLogStore.logConnect("home connection ownership changed", detail: "active=\(active) pathDepth=\(pairingCoordinator.path.count) pairingConfirmed=\(pairingCoordinator.userConfirmedPairingDevice) binding=\(pairingCoordinator.isBindingDevice) selected=\(authSession.selectedHomeDeviceKey ?? "nil")")
            guard active else { return }
            synchronizeConnectedHomeCard(reason: "home-root-resumed")
            refreshBatteryFromBLEIfNeeded()
        }
        .onChangeCompat(of: ble.deviceSN) { _ in
            if canManageHomeConnection { synchronizeConnectedHomeCard(reason: "device-identity-updated") }
        }
        .task(id: homeConnectionTarget) {
            // Do not connect to every card passed during a swipe.
            guard homeConnectionTarget != nil else { return }
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            connectSelectedHomeDevice(reason: "home-card-selection")
        }
        .onChangeCompat(of: scenePhase) { phase in
            if phase == .active {
                systemVolume.refresh()
                synchronizeConnectedHomeCard(reason: "app-active")
                // 回前台时系统蓝牙可能已连上，主动接管 GATT（不必等切 Tab）。
                refreshBatteryFromBLEIfNeeded()
            }
        }
        .onChangeCompat(of: homeBoundDeviceIdentities) { identities in
            // 用户信息异步返回后，再尝试连接并读电量
            if !identities.isEmpty {
                if canManageHomeConnection { synchronizeConnectedHomeCard(reason: "bound-devices-loaded") }
                connectSelectedHomeDevice(reason: "userInfoLoaded")
            }
        }
    }

    @ViewBuilder
    private var mediaActionToast: some View {
        if let mediaActionToastMessage {
            Text(mediaActionToastMessage)
                .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Color.black.opacity(0.80))
                .clipShape(Capsule())
                .padding(.horizontal, 24)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var scrollContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header
                DeviceCarouselSection(
                    ble: pairingCoordinator.astraA1BleManager,
                    cards: homeDeviceCards,
                    selectedDeviceIndex: Binding(get: { selectedDeviceIndex }, set: { selectedDeviceIndex = $0 }),
                    showsTabBar: $showsTabBar,
                    reconnectingDeviceID: $reconnectingDeviceID,
                    reconnectFailure: $reconnectFailure,
                    onHardReconnectFailed: showHardReconnectFailureGuidance,
                    onFindDeviceTap: openPairingFlowFromHome,
                    onOpenSettings: openGlassesSettings,
                    onEditName: { editingDevice = $0 },
                    onReconnectDevice: reconnectBoundDevice
                )
                volumeSection
                    .overlay(alignment: .bottom) {
                        mediaActionToast
                            .offset(y: 18)
                    }
                    .zIndex(1)
                actionGrid
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
        .refreshable {
            await reloadHomeDeviceState(userInitiated: true)
        }
    }

    private var photoButtonTitle: String {
        if ble.photoCompleted { return L10n.t("拍照完成", "Photo taken") }
        if ble.isTakingPhoto { return L10n.t("拍照中...", "Taking photo...") }
        return L10n.t("拍照", "Photo")
    }

    private var videoButtonTitle: String {
        if ble.videoCompleted { return L10n.t("录制完成", "Recording done") }
        if ble.isVideoStopping { return L10n.t("停止中...", "Stopping...") }
        if ble.deviceRuntimeStatus == .videoRecording || ble.isVideoRecording {
            return L10n.t("结束录像", "Stop Video")
        }
        return L10n.t("录像", "Video")
    }

    private func takePhoto() {
        guard !isAnyDeviceFileImportActive else {
            showMediaActionToast(L10n.t("正在导入文件，请稍后再试", "Import in progress, try again later"))
            return
        }
        ble.takePhotoFromHome()
    }

    private func toggleVideoRecording() {
        guard !isAnyDeviceFileImportActive else {
            showMediaActionToast(L10n.t("正在导入文件，请稍后再试", "Import in progress, try again later"))
            return
        }
        ble.toggleVideoRecordingFromHome()
    }

    private var isAnyDeviceFileImportActive: Bool {
        importManager.isImporting || recordingImportManager.isImporting
    }

    /// 首页入口：切到 AI Tab → 插 loading → 发 imgreccap0 → 收图后进聊天列表。
    private func startSmartImageRecognition() {
        guard ble.isDeviceAvailable else {
            mediaActionAlertMessage = L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
            return
        }
        guard !ble.isBatteryTooLowForMedia else {
            mediaActionAlertMessage = ble.lowBatteryMediaMessage
            return
        }
        guard !isAnyDeviceFileImportActive else {
            showMediaActionToast(L10n.t("正在导入文件，请稍后再试", "Import in progress, try again later"))
            return
        }
        if ble.deviceRuntimeStatus != .standby, ble.deviceRuntimeStatus != .unknown {
            showMediaActionToast(ble.deviceRuntimeStatus.busyMessage)
            return
        }

        tabRouter.openAITab()
        AIChatSession.shared.beginImageRecognitionCapture()
        _ = aiVisionTransfer.startCapture()
    }

    private func showMediaActionToast(_ message: String) {
        let toastID = UUID()
        mediaActionToastID = toastID
        mediaActionToastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if mediaActionToastID == toastID {
                mediaActionToastMessage = nil
            }
        }
    }

    private func isDeviceBusyMessage(_ message: String) -> Bool {
        let busyStatuses: [AstraA1BleProtocol.DeviceRuntimeStatus] = [
            .photoTaking,
            .videoRecording,
            .voiceRecording,
            .fileImporting,
            .aiVisionOperating,
            .firmwareUpgrading,
            .networkOperating,
            .shuttingDown,
            .unknown
        ]
        return busyStatuses.contains { $0.busyMessage == message }
    }

    private func openNewbieGuide() {
        guard ble.isDeviceAvailable else {
            mediaActionAlertMessage = L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
            return
        }
        guard !navigateToNewbieGuide else { return }
        tabRouter.performPushAfterReleasingTabInset(blackBackdrop: true) {
            navigateToNewbieGuide = true
        }
    }

    private func openAIRecording() {
        // 与 Android 首页一致：一代设备按键录音单独处理，暂不开放手动录音入口。
        guard ble.deviceGeneration != .gen1G5K61 else {
            showMediaActionToast(L10n.t("一代设备录音功能暂未开放", "Recording is not available for Gen 1 devices yet"))
            return
        }
        guard ble.isDeviceAvailable else {
            mediaActionAlertMessage = L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
            return
        }
        guard !navigateToAIRecording else { return }
        tabRouter.performPushAfterReleasingTabInset {
            navigateToAIRecording = true
        }
    }

    private func openAITranslation() {
        guard ble.isDeviceAvailable else {
            mediaActionAlertMessage = L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
            return
        }
        guard !navigateToAITranslation else { return }
        tabRouter.performPushAfterReleasingTabInset {
            navigateToAITranslation = true
        }
    }

    private func openOperationGuide() {
        guard ble.isDeviceAvailable else {
            mediaActionAlertMessage = L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
            return
        }
        guard !navigateToOperationGuide else { return }
        tabRouter.performPushAfterReleasingTabInset {
            navigateToOperationGuide = true
        }
    }

    private func openGlassesSettings(_ device: DeviceCardData) {
        guard !navigateToGlassesSettings else { return }
        settingsDevice = device
        tabRouter.performPushAfterReleasingTabInset {
            navigateToGlassesSettings = true
        }
    }

    private func openSoundEffectMode() {
        guard ble.isDeviceAvailable else {
            mediaActionAlertMessage = L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
            return
        }
        _ = ble.querySoundEffectMode()
        showSoundEffectSheet = true
    }

    private func reloadHomeDeviceState(userInitiated: Bool = false) async {
        synchronizeConnectedHomeCard(reason: "home-refresh")
        // A slow/offline userinfo request must not block the user's BLE retry.
        if userInitiated { retrySelectedHomeDevice(reason: "home-pull-refresh") }
        let selection = authSession.selectedHomeDeviceKey
        await authSession.refreshUserInfo()
        // A swipe during the HTTP request must keep its newly selected target.
        guard homeIsVisible, authSession.selectedHomeDeviceKey == selection else { return }
        synchronizeConnectedHomeCard(reason: "home-refresh-completed")
        refreshBatteryFromBLEIfNeeded()
    }

    private func synchronizeConnectedHomeCard(reason: String) {
        guard canManageHomeConnection else { return }
        let cards = homeDeviceCards.filter { !$0.isFindDevice }
        let connected = ble.isReady ? cards.first(where: {
            ble.matchesCurrentDevice(serialNumber: $0.serialNumber, hardwareSN: $0.hardwareSN)
        }) : nil
        let key = HomeDeviceSelection.keyOnReturn(
            selected: authSession.selectedHomeDeviceKey ?? ble.savedPeripheralUUIDString,
            connected: connected.map { $0.serialNumber ?? $0.id },
            bound: cards.map { $0.serialNumber ?? $0.id }
        )
        guard key != authSession.selectedHomeDeviceKey else { return }
        DebugLogStore.logConnect("home card synchronized", detail: "reason=\(reason) previous=\(authSession.selectedHomeDeviceKey ?? "nil") selected=\(key ?? "nil") connected=\(connected?.serialNumber ?? "nil")")
        authSession.selectedHomeDeviceKey = key
    }

    private func refreshBatteryFromBLEIfNeeded() {
        let hasBoundDevices = !(authSession.userInfo?.device.isEmpty ?? true)
        guard hasBoundDevices else { return }
        connectSelectedHomeDevice(reason: "homeAppear")
    }

    private var isHomeDeviceSwitchBusy: Bool {
        importManager.isImporting || recordingImportManager.isImporting
            || ble.isFirmwareUpgradeFlowBusy || ble.isAIVisionTransferBusy
            || ble.isVideoRecording || ble.isVideoStopping || ble.isTakingPhoto || ble.isAIRecording
    }

    private var homeConnectionTarget: String? {
        guard canManageHomeConnection else { return nil }
        let cards = homeDeviceCards
        guard cards.indices.contains(selectedDeviceIndex), !cards[selectedDeviceIndex].isFindDevice else { return nil }
        return cards[selectedDeviceIndex].serialNumber
    }

    private var canManageHomeConnection: Bool {
        HomeDeviceSelection.canManageConnection(
            homeIsVisible: homeIsVisible && tabRouter.selectedTab == .glasses,
            pairingInProgress: !pairingCoordinator.path.isEmpty
                || pairingCoordinator.showSearchingSheet || pairingCoordinator.isBindingDevice
                || pairingCoordinator.userConfirmedPairingDevice,
            hasPresentedPage: tabBarSuppressionCount > 0 || navigateToNewbieGuide
                || navigateToOperationGuide || navigateToGlassesSettings
                || navigateToAIRecording || navigateToAITranslation
        )
    }

    private func connectSelectedHomeDevice(reason: String) {
        guard let serial = homeConnectionTarget,
              let id = UUID(uuidString: serial.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let isCurrent = ble.savedPeripheralUUIDString?.caseInsensitiveCompare(id.uuidString) == .orderedSame
        if (!isCurrent && isHomeDeviceSwitchBusy)
            || !ble.selectBoundHomeDevice(peripheralID: id, reason: reason) {
            if let current = ble.savedPeripheralUUIDString {
                authSession.selectedHomeDeviceKey = current
            }
            mediaActionAlertMessage = L10n.t("眼镜正在执行任务，请结束后再切换设备", "The glasses are busy. Finish the current task before switching devices.")
        }
    }

    /// A user tap retries the exact bound card even without classic audio connectivity.
    private func reconnectBoundDevice(_ card: DeviceCardData) {
        guard canManageHomeConnection, reconnectingDeviceID == nil,
              !card.isFindDevice,
              let serial = card.serialNumber,
              let id = UUID(uuidString: serial.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        if ble.savedPeripheralUUIDString?.caseInsensitiveCompare(id.uuidString) != .orderedSame,
           isHomeDeviceSwitchBusy {
            mediaActionAlertMessage = L10n.t("眼镜正在执行任务，请结束后再切换设备", "The glasses are busy. Finish the current task before switching devices.")
            return
        }
        authSession.selectedHomeDeviceKey = serial
        reconnectFailure = nil
        let started = ble.retryBoundHomeDevice(peripheralID: id, reason: "home-card-tap")
        if started, ble.isConnectionInProgress || ble.connectionState == .scanning {
            reconnectingDeviceID = card.id
            scheduleReconnectTimeout(for: card.id)
        }
    }

    private func retrySelectedHomeDevice(reason: String) {
        guard let serial = homeConnectionTarget,
              let id = UUID(uuidString: serial.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        if ble.savedPeripheralUUIDString?.caseInsensitiveCompare(id.uuidString) != .orderedSame,
           isHomeDeviceSwitchBusy { return }
        _ = ble.retryBoundHomeDevice(peripheralID: id, reason: reason)
    }

    /// 兜底超时：BLE 侧扫描/连接超时通常先到，这里防止状态卡住转圈不停。
    private func scheduleReconnectTimeout(for cardID: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            guard reconnectingDeviceID == cardID else { return }
            let ble = pairingCoordinator.astraA1BleManager
            guard !ble.isReady else { return }
            reconnectingDeviceID = nil
            reconnectFailure = DeviceReconnectFailure(
                deviceID: cardID,
                isNotFound: !ble.isConnectionInProgress
            )
            showHardReconnectFailureGuidance()
        }
    }

    private func showHardReconnectFailureGuidance() {
        showHardReconnectFailureAlert = true
    }

    private func openPairingFlowFromHome() {
        guard pairingCoordinator.path.isEmpty else { return }
        // path 非空后由 MainTabView 继续藏 Tab；此处 immersive 仅桥接 push 前两帧。
        tabRouter.performPushAfterReleasingTabInset {
            pairingCoordinator.openPairingFlow()
            tabRouter.endImmersiveCover()
            updateTabBarVisibility()
        }
    }

    private func updateTabBarVisibility() {
        showsTabBar = tabBarSuppressionCount == 0 && pairingCoordinator.path.isEmpty
            && !navigateToGlassesSettings
    }

    @ViewBuilder
    private func pairingPreparationScreen(onBack: @escaping () -> Void) -> some View {
        PairingPreparationView(onBack: onBack)
            .environmentObject(pairingCoordinator)
            .environmentObject(authSession)
    }

    @ViewBuilder
    private func pairingScreen<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            content()
        }
        .background(AppTheme.background.ignoresSafeArea())
        .compatibleNavigationContainerBackground(AppTheme.background)
        .navigationControllerBackground()
    }

    private var header: some View {
        HStack {
            Text(L10n.t("设备", "Devices"))
                .font(AppTheme.notoSansSC(size: HomeLayout.screenTitleSize, weight: .bold))
                .tracking(0)
                .lineSpacing(0)
                .foregroundStyle(AppTheme.primaryText)

            Spacer()

            Button {
                openPairingFlowFromHome()
            } label: {
                Image("android_index_add")
                    .resizable()
                    .scaledToFit()
                    .frame(width: HomeLayout.plusButtonSize, height: HomeLayout.plusButtonSize)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("系统音量", "System Volume"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)

            HStack(spacing: 10) {
                Image("android_home_volume")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)

                VolumeSlider(
                    value: Binding(
                        get: { systemVolume.volume },
                        set: { if ble.isDeviceAvailable { systemVolume.setVolume($0) } }
                    ),
                    isEnabled: ble.isDeviceAvailable,
                    onEditingChanged: { isDragging in
                        systemVolume.setUserDragging(isDragging)
                    }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: HomeLayout.volumeCardWidth, height: HomeLayout.volumeCardHeight, alignment: .topLeading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius))
        .shadow(color: AppTheme.cardShadow, radius: 10, y: 4)
        .frame(maxWidth: .infinity)
        .opacity(ble.isDeviceAvailable ? 1 : 0.45)
        .allowsHitTesting(ble.isDeviceAvailable)
    }

    private var actionGrid: some View {
        VStack(spacing: HomeLayout.actionCardSpacing) {
            HStack(spacing: HomeLayout.actionCardSpacing) {
                if showsCapability(\.photo) {
                    Button {
                        takePhoto()
                    } label: {
                        MediaActionCardView(
                            title: photoButtonTitle,
                            iconName: "android_home_photo"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!ble.isDeviceAvailable || ble.isTakingPhoto || ble.photoCompleted)
                    .opacity(ble.isDeviceAvailable ? 1 : 0.45)
                }

                if showsCapability(\.video) {
                    Button {
                        toggleVideoRecording()
                    } label: {
                        MediaActionCardView(
                            title: videoButtonTitle,
                            iconName: "android_home_video"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!ble.isDeviceAvailable || ble.isVideoStopping || ble.videoCompleted)
                    .opacity(ble.isDeviceAvailable ? 1 : 0.45)
                }
            }

            HStack(spacing: HomeLayout.actionCardSpacing) {
                if showsCapability(\.aiRecording) {
                    Button {
                        openAIRecording()
                    } label: {
                        FeatureActionCardView(
                            title: L10n.t("AI录音", "AI Recording"),
                            subtitle: L10n.t("随时记录，AI转写总结", "Record anytime, AI transcription & summary"),
                            iconName: "android_home_recording"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!ble.isDeviceAvailable)
                    .opacity(ble.isDeviceAvailable ? 1 : 0.45)
                    .background {
                        NavigationLink(
                            isActive: $navigateToAIRecording,
                            destination: {
                                AIRecordingListView()
                            },
                            label: { EmptyView() }
                        )
                        .hidden()
                    }
                }

                if showsCapability(\.translation) {
                    Button {
                        openAITranslation()
                    } label: {
                        FeatureActionCardView(
                            title: L10n.t("AI翻译", "AI Translation"),
                            subtitle: L10n.t("支持多种语言，让对话交流更顺畅自然", "Multi-language support for smoother conversations"),
                            iconName: "android_home_translation"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!ble.isDeviceAvailable)
                    .opacity(ble.isDeviceAvailable ? 1 : 0.45)
                    .background {
                        NavigationLink(
                            isActive: $navigateToAITranslation,
                            destination: {
                                AITranslationHomeView()
                            },
                            label: { EmptyView() }
                        )
                        .hidden()
                    }
                }
            }

            HStack(spacing: HomeLayout.actionCardSpacing) {
                if showsCapability(\.aiImageRecognition) {
                    Button {
                        startSmartImageRecognition()
                    } label: {
                        FeatureActionCardView(
                            title: L10n.t("智能图像识别", "Smart Image Recognition"),
                            subtitle: L10n.t("第一人称视觉助手，识别眼前万物，并解说信息", "First-person vision assistant that recognizes and explains what you see"),
                            iconName: "android_home_recognition"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!ble.isDeviceAvailable)
                    .opacity(ble.isDeviceAvailable ? 1 : 0.45)
                }

                if showsCapability(\.eq) {
                    Button {
                        openSoundEffectMode()
                    } label: {
                        FeatureActionCardView(
                            title: selectedSoundMode.cardTitle,
                            subtitle: L10n.t("音效模式", "Sound Mode"),
                            iconName: selectedSoundMode.cardIconName
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!ble.isDeviceAvailable)
                    .opacity(ble.isDeviceAvailable ? 1 : 0.45)
                }
            }

            HStack(spacing: HomeLayout.actionCardSpacing) {
                if showsCapability(\.tutorial) {
                    Button {
                        openNewbieGuide()
                    } label: {
                        GuideActionCardView(
                            title: L10n.t("新手引导", "Newbie Guide"),
                            subtitle: L10n.t("快速掌握基础操作", "Learn the basics quickly"),
                            iconName: "android_home_newbie"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!ble.isDeviceAvailable)
                    .opacity(ble.isDeviceAvailable ? 1 : 0.45)
                    .background {
                        NavigationLink(
                            isActive: $navigateToNewbieGuide,
                            destination: {
                                NewbieGuideView(
                                    ble: ble,
                                    modelName: currentGuideModelName,
                                    token: authSession.token,
                                    onClose: { navigateToNewbieGuide = false }
                                )
                            },
                            label: { EmptyView() }
                        )
                        .hidden()
                    }
                }

                Button {
                    openOperationGuide()
                } label: {
                    GuideActionCardView(
                        title: L10n.t("操作指南", "Operation Guide"),
                        subtitle: L10n.t("按键及触控板操作", "Buttons and touchpad"),
                        iconName: "android_home_operation"
                    )
                }
                .buttonStyle(.plain)
                .disabled(!ble.isDeviceAvailable)
                .opacity(ble.isDeviceAvailable ? 1 : 0.45)
                .background {
                    NavigationLink(
                        isActive: $navigateToOperationGuide,
                        destination: {
                            OperationGuideView(
                                modelName: currentGuideModelName,
                                token: authSession.token
                            )
                        },
                        label: { EmptyView() }
                    )
                    .hidden()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            NavigationLink(
                isActive: $navigateToGlassesSettings,
                destination: {
                    GlassesSettingsView(device: settingsDevice, suppressesTabBarOnAppear: false)
                },
                label: { EmptyView() }
            )
            .hidden()
        }
    }
}

/// 设备卡片轮播区：直接观察 BLE 管理器，连接状态变化即刷新。
private struct DeviceCarouselSection: View {
    @ObservedObject var ble: AstraA1BleManager
    let cards: [DeviceCardData]
    @Binding var selectedDeviceIndex: Int
    @State private var scrollSelection = HomeCarouselSelection()
    @Binding var showsTabBar: Bool
    @Binding var reconnectingDeviceID: String?
    @Binding var reconnectFailure: DeviceReconnectFailure?
    let onHardReconnectFailed: () -> Void
    let onFindDeviceTap: () -> Void
    let onOpenSettings: (DeviceCardData) -> Void
    let onEditName: (DeviceCardData) -> Void
    let onReconnectDevice: (DeviceCardData) -> Void

    /// 扫描阶段为「正在搜索设备」，进入 GATT 流程后为「正在连接」。
    private func reconnectPhase(for device: DeviceCardData) -> DeviceReconnectPhase {
        guard !device.isConnected else { return .none }
        if isConnecting(device) || reconnectingDeviceID == device.id {
            switch ble.connectionState {
            case .connecting, .discoveringServices, .enablingNotifications:
                return .connecting
            default:
                return .searching
            }
        }
        if isManualHardRetryTarget(device) {
            return .hardRetryRequired
        }
        guard let failure = reconnectFailure, failure.deviceID == device.id else { return .none }
        return failure.isNotFound ? .notFound : .failed
    }

    private func isManualHardRetryTarget(_ device: DeviceCardData) -> Bool {
        guard let required = ble.manualHardReconnectPeripheralUUIDString else { return false }
        let serial = device.serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if serial.caseInsensitiveCompare(required) == .orderedSame { return true }
        let realCards = cards.filter { !$0.isFindDevice }
        return realCards.count == 1 && ble.savedPeripheralUUIDString == required
    }

    /// 多眼镜场景只在当前 GATT 目标卡片显示连接中，避免所有未连接卡片一起变更文案。
    private func isConnecting(_ device: DeviceCardData) -> Bool {
        guard ble.isConnectionInProgress || ble.isBoundConnectionSearchInProgress,
              !device.isFindDevice, !device.isConnected else {
            return false
        }
        let realCards = cards.filter { !$0.isFindDevice }
        return realCards.count == 1 || matchesLiveBLEDevice(device)
    }

    private var devices: [DeviceCardData] {
        cards.map { card in
            guard !card.isFindDevice else { return card }
            let connected = ble.isDeviceAvailable && matchesLiveBLEDevice(card)
            let model: GlassDeviceModel
            switch ble.deviceGeneration {
            case .gen1G5K61: model = .luminaL1
            case .gen2: model = .astraA1
            case .unknown: model = GlassDeviceModel(modelName: card.modelName ?? "")
            }
            return card.withConnection(
                isConnected: connected,
                batteryPercent: connected ? ble.deviceBatteryPercent : nil,
                isCharging: connected ? ble.deviceIsCharging : false,
                connectedImageName: model.connectedImageName
            )
        }
    }

    /// The home card and operation gate share the same current-peripheral identity check.
    private func matchesLiveBLEDevice(_ card: DeviceCardData) -> Bool {
        !card.isFindDevice && ble.matchesCurrentDevice(
            serialNumber: card.serialNumber, hardwareSN: card.hardwareSN
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            carousel
            if devices.count > 1 {
                pageIndicator
            }
        }
        .onChangeCompat(of: ble.isReady) { ready in
            guard ready else { return }
            reconnectingDeviceID = nil
            reconnectFailure = nil
        }
        .onChangeCompat(of: ble.connectionState) { state in
            switch state {
            case .failed:
                guard let cardID = reconnectingDeviceID else { return }
                reconnectingDeviceID = nil
                onHardReconnectFailed()
                if ble.manualHardReconnectPeripheralUUIDString != nil {
                    reconnectFailure = nil
                } else {
                    reconnectFailure = DeviceReconnectFailure(
                        deviceID: cardID,
                        isNotFound: ble.lastManualReconnectFailure != .connectFailed
                    )
                }
            case .disconnected, .bluetoothUnavailable:
                let hardReconnectWasActive = reconnectingDeviceID != nil
                reconnectingDeviceID = nil
                reconnectFailure = nil
                if hardReconnectWasActive {
                    onHardReconnectFailed()
                }
            case .idle:
                reconnectingDeviceID = nil
                reconnectFailure = nil
            default:
                break
            }
        }
    }

    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        DeviceCardView(
                            device: device,
                            showsTabBar: $showsTabBar,
                            isConnecting: isConnecting(device),
                            reconnectPhase: reconnectPhase(for: device),
                            onFindDeviceTap: onFindDeviceTap,
                            onOpenSettings: { onOpenSettings(device) },
                            onEditName: { onEditName(device) },
                            onReconnectTap: { onReconnectDevice(device) }
                        )
                        .frame(
                            width: HomeLayout.deviceCardWidth,
                            height: HomeLayout.deviceCardHeight
                        )
                        .id(index)
                    }
                }
                .compatibleScrollTargetLayout()
                .padding(.horizontal, HomeLayout.horizontalMargin)
            }
            .compatibleScrollTargetBehaviorViewAligned()
            .simultaneousGesture(DragGesture().onChanged { _ in
                scrollSelection.beginUserScroll()
            }.onEnded { value in
                if #available(iOS 17.0, *) { return }
                guard !devices.isEmpty else { return }
                // iOS 15/16 lack scrollPosition; settle on the selected card explicitly.
                let stride = HomeLayout.deviceCardWidth + 12
                let offset = Int((-value.predictedEndTranslation.width / stride).rounded())
                selectedDeviceIndex = min(max(selectedDeviceIndex + offset, 0), devices.count - 1)
                proxy.scrollTo(selectedDeviceIndex, anchor: .center)
            })
            .compatibleScrollPosition(id: Binding(
                get: { scrollSelection.index },
                set: { newValue in
                    if let index = scrollSelection.receiveVisibleIndex(newValue) {
                        selectedDeviceIndex = index
                        if selectedDeviceIndex != index {
                            scrollSelection.synchronize(to: selectedDeviceIndex)
                        }
                    }
                }
            ))
            .frame(height: HomeLayout.deviceCardHeight)
            .onAppear {
                scrollSelection.synchronize(to: selectedDeviceIndex)
                proxy.scrollTo(selectedDeviceIndex, anchor: .center)
            }
            .onChangeCompat(of: selectedDeviceIndex) { index in
                if scrollSelection.index != index { scrollSelection.synchronize(to: index) }
                proxy.scrollTo(index, anchor: .center)
            }
            .onChangeCompat(of: cards.map(\.id)) { _ in
                scrollSelection.synchronize(to: selectedDeviceIndex)
                proxy.scrollTo(selectedDeviceIndex, anchor: .center)
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<devices.count, id: \.self) { index in
                Capsule()
                    .fill(index == selectedDeviceIndex ? AppTheme.accent : Color(red: 0.85, green: 0.85, blue: 0.85))
                    .frame(width: index == selectedDeviceIndex ? 20 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: selectedDeviceIndex)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }
}

/// 点卡片手动重连的阶段，驱动卡片文案与菊花。
enum DeviceReconnectPhase {
    case none
    case searching
    case connecting
    case notFound
    case failed
    case hardRetryRequired

    var isBusy: Bool {
        self == .searching || self == .connecting
    }

    var allowsCardRetry: Bool {
        self == .none || self == .notFound || self == .failed || self == .hardRetryRequired
    }

    var statusText: String? {
        switch self {
        case .none: return nil
        case .searching: return L10n.t("正在搜索设备", "Searching for devices")
        case .connecting: return L10n.t("正在连接", "Connecting")
        case .notFound: return L10n.t("未找到设备", "Device not found")
        case .failed: return L10n.t("设备连接失败", "Connection failed")
        case .hardRetryRequired: return L10n.t("连接失败，请点击重试", "Connection failed. Tap to retry.")
        }
    }
}

struct DeviceReconnectFailure: Equatable {
    let deviceID: String
    let isNotFound: Bool
}

private struct DeviceCardView: View {
    let device: DeviceCardData
    @Binding var showsTabBar: Bool
    var isConnecting: Bool = false
    var reconnectPhase: DeviceReconnectPhase = .none
    var onFindDeviceTap: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onEditName: () -> Void = {}
    var onReconnectTap: () -> Void = {}

    var body: some View {
        Group {
            if device.isFindDevice {
                Button(action: onFindDeviceTap) {
                    cardContent
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    cardContent

                    // Keep the connected card's settings/name actions available.
                    if !device.isConnected, !isConnecting, reconnectPhase.allowsCardRetry {
                        Button(action: onReconnectTap) {
                            Color.clear
                                .contentShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.t("重新连接眼镜", "Reconnect glasses"))
                    }
                }
            }
        }
    }

    private var disconnectedStatusText: String {
        if let text = reconnectPhase.statusText { return text }
        return isConnecting ? L10n.t("正在连接...", "Connecting...") : L10n.t("设备未连接", "Not connected")
    }

    private var brandName: String {
        let value = device.eqName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "MOCO" : value
    }

    private var cardContent: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    if device.isFindDevice {
                        Text(L10n.t("查找您的设备", "Find your device"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.primaryText)
                    } else {
                        // Android item_glasses：品牌一行，设备名一行，电量/连接状态一行。
                        HStack(spacing: 3) {
                            Image("android_index_logo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 22, height: 22)

                            Text(brandName)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AppTheme.primaryText)
                        }
                        .frame(height: 22)

                        Button(action: onEditName) {
                            HStack(spacing: 5) {
                                Text(device.name ?? "")
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(AppTheme.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Image("android_index_edit")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 16, height: 16)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)

                        if device.isConnected {
                            if let battery = device.batteryPercent {
                                HStack(spacing: 6) {
                                    Image(BatteryIcon.assetName(for: battery, isCharging: device.isCharging))
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 24, height: 24)
                                    (
                                        Text("\(battery)")
                                            .font(.system(size: 15, weight: .bold))
                                        + Text("%")
                                            .font(.system(size: 15, weight: .regular))
                                    )
                                        .foregroundStyle(AppTheme.primaryText)
                                }
                                .padding(.horizontal, 3)
                            } else {
                                Text(L10n.t("已连接", "Connected"))
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color(red: 184 / 255, green: 184 / 255, blue: 184 / 255))
                            }
                        } else if !device.isFindDevice {
                            Text(disconnectedStatusText)
                                .font(.system(size: 14))
                                .foregroundStyle(Color(red: 184 / 255, green: 184 / 255, blue: 184 / 255))
                        }
                    }
                }

                Spacer()

                if !device.isFindDevice {
                    Button(action: onOpenSettings) {
                        Image("android_index_settings")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer(minLength: 0)

            Image(device.imageName)
                .resizable()
                .scaledToFit()
                .frame(
                    width: HomeLayout.glassImageWidth,
                    height: HomeLayout.glassImageHeight
                )
                .opacity(device.isFindDevice ? 0.5 : (device.isConnected ? 1 : 0.55))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius))
        .shadow(color: AppTheme.cardShadow, radius: 10, y: 4)
    }
}

private struct DeviceNameEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var draftName: String

    let onSave: (String) -> Void

    init(currentName: String, onSave: @escaping (String) -> Void) {
        _draftName = State(initialValue: currentName)
        self.onSave = onSave
    }

    private var normalizedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(L10n.t("修改设备名称", "Edit Device Name"))
                .font(AppTheme.notoSansSC(size: 17, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)

            TextField(L10n.t("请输入设备名称", "Enter device name"), text: $draftName)
                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .focused($isNameFocused)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color(red: 0.95, green: 0.95, blue: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text(L10n.t("取消", "Cancel"))
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color(red: 0.90, green: 0.90, blue: 0.90))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: save) {
                    Text(L10n.t("确定", "Confirm"))
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(normalizedName.isEmpty)
                .opacity(normalizedName.isEmpty ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardBackground)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isNameFocused = true
            }
        }
    }

    private func save() {
        guard !normalizedName.isEmpty else { return }
        onSave(normalizedName)
        dismiss()
    }
}

private struct VolumeSlider: View {
    @Binding var value: Double
    var isEnabled: Bool = true
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let trackHeight: CGFloat = 12
            let fillWidth = max(0, CGFloat(value) * geometry.size.width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(red: 0.90, green: 0.90, blue: 0.90))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color.black)
                    .frame(width: fillWidth, height: trackHeight)

            }
            .frame(height: trackHeight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let newValue = gesture.location.x / geometry.size.width
                        value = min(max(newValue, 0), 1)
                    }
                    .onEnded { gesture in
                        if isEnabled {
                            let newValue = gesture.location.x / geometry.size.width
                            value = min(max(newValue, 0), 1)
                        }
                        if isDragging {
                            isDragging = false
                            onEditingChanged(false)
                        }
                    }
            )
            .allowsHitTesting(isEnabled)
        }
        .frame(height: 18)
    }
}

private struct MediaActionCardView: View {
    let title: String
    let iconName: String

    var body: some View {
        HStack(spacing: 12) {
            Image(iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)

            Text(title)
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: HomeLayout.actionCardWidth, height: HomeLayout.mediaActionCardHeight)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius))
        .shadow(color: AppTheme.cardShadow, radius: 10, y: 4)
    }
}

private struct FeatureActionCardView: View {
    let title: String
    let subtitle: String
    let iconName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .font(AppTheme.notoSansSC(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
            }

            Text(subtitle)
                .font(AppTheme.notoSansSC(size: 11, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 4)
        }
        .padding(12)
        .frame(width: HomeLayout.actionCardWidth, height: HomeLayout.featureActionCardHeight, alignment: .topLeading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius))
        .shadow(color: AppTheme.cardShadow, radius: 10, y: 4)
    }
}

private struct GuideActionCardView: View {
    let title: String
    let subtitle: String
    let iconName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .font(AppTheme.notoSansSC(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)

                Spacer(minLength: 4)

                Image(iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
            }

            Text(subtitle)
                .font(AppTheme.notoSansSC(size: 11, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(2)
        }
        .padding(12)
        .frame(width: HomeLayout.actionCardWidth, height: HomeLayout.actionCardHeight, alignment: .topLeading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius))
        .shadow(color: AppTheme.cardShadow, radius: 10, y: 4)
    }
}

#Preview {
    HomeView(showsTabBar: .constant(true))
        .environmentObject(PairingCoordinator())
        .environmentObject(AuthSession())
        .environmentObject(MainTabRouter())
        .environmentObject(AiVisionTransferManager())
        .environmentObject(MediaImportManager.shared)
        .environmentObject(AIRecordingImportManager.shared)
}
