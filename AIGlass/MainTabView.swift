import SwiftUI
import UIKit

enum TabItem: Int, CaseIterable {
    case glasses
    case ai
    case album
    case profile

    @MainActor
    var title: String {
        switch self {
        case .glasses: L10n.t("眼镜", "Glasses")
        case .ai: L10n.t("AI", "AI")
        case .album: L10n.t("相册", "Gallery")
        case .profile: L10n.t("我的", "Me")
        }
    }

    var iconName: String {
        switch self {
        case .glasses: "android_tab_glasses"
        case .ai: "android_tab_ai"
        case .album: "android_tab_album"
        case .profile: "android_tab_profile"
        }
    }

    var selectedIconName: String {
        switch self {
        case .glasses: "android_tab_glasses_selected"
        case .ai: "android_tab_ai_selected"
        case .album: "android_tab_album_selected"
        case .profile: "android_tab_profile_selected"
        }
    }
}

enum TabBarLayout {
    static let contentInset: CGFloat = 88
}

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var authSession: AuthSession
    @ObservedObject private var languageManager = AppLanguageManager.shared
    @StateObject private var tabRouter = MainTabRouter()
    @StateObject private var aiVisionTransfer = AiVisionTransferManager()
    @StateObject private var aiVoiceChat = AIVoiceChatManager.shared
    @State private var showsTabBar = true
    /// App 级对象：普通退出登录后继续保留 BLE，与 Android 前台服务一致。
    @EnvironmentObject private var pairingCoordinator: PairingCoordinator
    @StateObject private var importManager = MediaImportManager.shared
    @StateObject private var recordingStore = AIRecordingStore.shared
    @StateObject private var recordingImportManager = AIRecordingImportManager.shared
    @StateObject private var deviceFirmwareUpdateCoordinator = DeviceFirmwareUpdateCoordinator()
    @StateObject private var bluetoothOtaUpgradeManager = BluetoothOtaUpgradeManager()
    @State private var showsGen1RecoveryPrompt = false
    @State private var deviceUpgradeSheet: DeviceUpdatePresentation?
    @State private var promptedGen1RecoveryTarget: String?
    @State private var deviceUpdatePrompt: DeviceUpdatePresentation?
    @State private var didShowDeviceUpdateThisSession = false

    /// 眼镜 Tab 内 push / 沉浸页隐藏 TabBar；导航容器尺寸保持不变。
    private var hidesTabBarForNavigation: Bool {
        (tabRouter.selectedTab == .glasses && !pairingCoordinator.path.isEmpty)
            || tabRouter.hidesTabBarForImmersiveCover
    }

    private var showsTabBarChrome: Bool {
        showsTabBar && !hidesTabBarForNavigation
    }

    var body: some View {
        // Keep navigation geometry stable during push/pop. Each tab root reserves
        // its own tab-bar space; destinations use the full safe-area viewport.
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                tabContent
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .id(languageManager.refreshID)

                customTabBar
                    .opacity(showsTabBarChrome ? 1 : 0)
                    .allowsHitTesting(showsTabBarChrome)
                    .accessibilityHidden(!showsTabBarChrome)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .overlay {
            if let presentation = deviceUpdatePrompt {
                BluetoothFirmwareUpdateDialog(
                    prompt: presentation.offer,
                    title: presentation.kind == .bluetooth
                        ? L10n.t("蓝牙固件升级", "Bluetooth Firmware Update")
                        : L10n.t("眼镜固件升级", "Glasses Firmware Update"),
                    onCancel: { deviceUpdatePrompt = nil },
                    onUpgrade: {
                        guard canPresentDeviceUpdate, isCurrentOrdinaryOffer(presentation) else {
                            deviceUpdatePrompt = nil
                            return
                        }
                        deviceUpdatePrompt = nil
                        deviceUpgradeSheet = presentation
                    }
                )
            }
        }
        .animation(.none, value: showsTabBar)
        .animation(.none, value: pairingCoordinator.path.count)
        .animation(.none, value: tabRouter.immersiveCoverCount)
        .environmentObject(pairingCoordinator)
        .environmentObject(importManager)
        .environmentObject(recordingStore)
        .environmentObject(recordingImportManager)
        .environmentObject(deviceFirmwareUpdateCoordinator)
        .environmentObject(bluetoothOtaUpgradeManager)
        .environmentObject(tabRouter)
        .environmentObject(aiVisionTransfer)
        .onAppear {
            pairingCoordinator.authSession = authSession
            recordingStore.updateCurrentUser(authSession.phoneNumber)
            bindAIVisionTransfer()
            bindAIVoiceChat()
            let available = pairingCoordinator.astraA1BleManager.isDeviceAvailable
            updateAudioConnectionState(available)
            scheduleFirmwareUpdateRefresh()
        }
        .onChangeCompat(of: languageManager.refreshID) { _ in
            // 语言切换会用新的 id 重建 tabContent，push 出去的页面被销毁后不会再走
            // onDisappear 还原，showsTabBar / 沉浸页计数会卡在隐藏态。
            showsTabBar = true
            tabRouter.resetChromeState()
            pairingCoordinator.path.removeAll()
        }
        .onChangeCompat(of: authSession.phoneNumber) { phone in
            if Gen1AiRecordingManager.shared.isRecording {
                _ = pairingCoordinator.astraA1BleManager.stopAIRecord()
            }
            recordingStore.updateCurrentUser(phone)
        }
        .onChangeCompat(of: authSession.userInfo?.bluetoothBySerialNumber) { _ in
            scheduleFirmwareUpdateRefresh()
        }
        .onChangeCompat(of: authSession.userInfo?.firmwareBySerialNumber) { _ in
            scheduleFirmwareUpdateRefresh()
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.isDeviceAvailable) { available in
            updateAudioConnectionState(available)
            if !available {
                aiVoiceChat.resetAfterDisconnect()
                promptedGen1RecoveryTarget = nil
                showsGen1RecoveryPrompt = false
                deviceUpdatePrompt = nil
            } else {
                showGen1RecoveryPromptIfNeeded()
            }
            // 升级补查交给 DeviceFirmwareUpdateCoordinator，避免与初连 getdevinfo 叠发。
            scheduleFirmwareUpdateRefresh()
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.deviceVersion2800) { _ in
            scheduleFirmwareUpdateRefresh()
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.deviceVersion6350) { _ in
            scheduleFirmwareUpdateRefresh()
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.isQueryingDeviceVersionsAndStorage) { querying in
            if !querying { scheduleFirmwareUpdateRefresh() }
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.isQueryingAboutDeviceInfo) { querying in
            if !querying { scheduleFirmwareUpdateRefresh() }
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.deviceBluetoothIdentifier) { _ in
            promptedGen1RecoveryTarget = nil
            showGen1RecoveryPromptIfNeeded()
            scheduleFirmwareUpdateRefresh()
        }
        .onChangeCompat(of: deviceFirmwareUpdateCoordinator.bluetoothUpdate) { _ in
            if deviceFirmwareUpdateCoordinator.bluetoothUpdate?.isGen1BluetoothRecovery != true {
                showsGen1RecoveryPrompt = false
            }
            showGen1RecoveryPromptIfNeeded()
        }
        .task(id: pairingCoordinator.navigationResetID) {
            // Present recovery guidance only after the replacement home stack settles.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            showGen1RecoveryPromptIfNeeded()
        }
        .task(id: deviceUpdatePromptEvaluationKey) {
            await showDeviceUpdatePromptIfNeeded()
        }
        .onChangeCompat(of: bluetoothOtaUpgradeManager.state) { newState in
            if case .completed = newState {
                Task { await authSession.refreshUserInfo() }
                scheduleFirmwareUpdateRefresh()
            } else if case .idle = newState {
                scheduleFirmwareUpdateRefresh()
            }
        }
        .alert(L10n.t("需要重新升级蓝牙固件", "Bluetooth Firmware Recovery Required"), isPresented: $showsGen1RecoveryPrompt) {
            Button(L10n.t("稍后", "Later"), role: .cancel) {}
            Button(L10n.t("立即升级", "Update now")) {
                guard let offer = deviceFirmwareUpdateCoordinator.bluetoothUpdate,
                      offer.isGen1BluetoothRecovery,
                      pairingCoordinator.astraA1BleManager.savedPeripheralUUIDString == offer.serialNumber else { return }
                deviceUpgradeSheet = DeviceUpdatePresentation(kind: .bluetooth, offer: offer)
            }
        } message: {
            Text(L10n.t("这副眼镜上次蓝牙固件升级未完成，请重新升级。若暂不升级，下次连接时会再次提醒。", "The previous Bluetooth firmware update for these glasses did not finish. Update again to recover. If you choose Later, you will be reminded on the next connection."))
        }
        .sheet(item: $deviceUpgradeSheet, onDismiss: {
            bluetoothOtaUpgradeManager.resetCompletedState()
            scheduleFirmwareUpdateRefresh()
        }) { presentation in
            DeviceOtaUpgradeDetailView(kind: presentation.kind, offer: presentation.offer, ble: pairingCoordinator.astraA1BleManager)
                .environmentObject(deviceFirmwareUpdateCoordinator)
                .environmentObject(bluetoothOtaUpgradeManager)
                .environmentObject(importManager)
                .environmentObject(authSession)
                .interactiveDismissDisabled(bluetoothOtaUpgradeManager.isUpgrading)
        }
    }

    /// Android：BLE 连接后准备经典蓝牙音频，再同步 STREAM_MUSIC；断连不写音量。
    /// iOS 顺序需按方向区分，避免路由切换把手机扬声器音量误当成眼镜音量。
    private func updateAudioConnectionState(_ connected: Bool) {
        if connected {
            GlassesAudioRouteController.setGlassesConnected(true)
            SystemVolumeController.shared.setGlassesConnected(true)
        } else {
            SystemVolumeController.shared.setGlassesConnected(false)
            GlassesAudioRouteController.setGlassesConnected(false)
        }
    }

    private func bindAIVisionTransfer() {
        let ble = pairingCoordinator.astraA1BleManager
        aiVisionTransfer.bind(ble: ble)
        // 已在 BLE MainActor 路径上：同步拼包，避免再套一层 Task 把包挤丢。
        ble.aiVisionNotifyHandler = { [weak aiVisionTransfer] command, data in
            aiVisionTransfer?.handleNotify(command: command, packet: data)
        }
        ble.aiVisionDeviceIdleHandler = { [weak aiVisionTransfer] in
            aiVisionTransfer?.handleDeviceBecameIdle()
        }
        aiVisionTransfer.onImageReceived = { [authSession] jpeg in
            AIChatSession.shared.completeImageRecognition(
                jpeg: jpeg,
                token: authSession.token
            )
        }
        aiVisionTransfer.onFailed = { message in
            AIChatSession.shared.failImageRecognition(message)
        }
        aiVisionTransfer.onProgress = { received, total in
            AIChatSession.shared.updateLoadingProgress(received: received, total: total)
        }
    }

    private func bindAIVoiceChat() {
        aiVoiceChat.bind(
            ble: pairingCoordinator.astraA1BleManager,
            tokenProvider: { [weak authSession] in authSession?.token }
        )
    }

    private func scheduleFirmwareUpdateRefresh() {
        deviceFirmwareUpdateCoordinator.scheduleRefresh(
            authSession: authSession,
            ble: pairingCoordinator.astraA1BleManager,
            otaManager: bluetoothOtaUpgradeManager
        )
    }

    private func showGen1RecoveryPromptIfNeeded() {
        let ble = pairingCoordinator.astraA1BleManager
        guard let offer = deviceFirmwareUpdateCoordinator.bluetoothUpdate,
              offer.isGen1BluetoothRecovery,
              ble.savedPeripheralUUIDString == offer.serialNumber,
              let targetID = UUID(uuidString: offer.serialNumber),
              Gen1BluetoothOtaRecoveryStore().record(for: targetID) != nil,
              scenePhase == .active,
              tabRouter.selectedTab == .glasses,
              pairingCoordinator.path.isEmpty,
              !pairingCoordinator.showSearchingSheet,
              !pairingCoordinator.userConfirmedPairingDevice,
              !pairingCoordinator.isBindingDevice,
              promptedGen1RecoveryTarget != offer.serialNumber,
              deviceUpgradeSheet == nil, !bluetoothOtaUpgradeManager.isUpgrading else { return }
        deviceUpdatePrompt = nil
        promptedGen1RecoveryTarget = offer.serialNumber
        showsGen1RecoveryPrompt = true
        DebugLogStore.logBLEEvent("Gen1 Bluetooth OTA recovery prompt", detail: "target=\(offer.serialNumber) targetVersion=\(offer.serverInfo.version) fresh_version_not_required")
    }

    private struct DeviceUpdatePresentation: Identifiable {
        let kind: OtaUpgradeKind
        let offer: DeviceFirmwareUpdateCoordinator.UpdateOffer
        var id: String { "\(kind == .bluetooth ? "bluetooth" : "firmware")|\(offer.id)" }
    }

    private var canPresentDeviceUpdate: Bool {
        let status = pairingCoordinator.astraA1BleManager.deviceRuntimeStatus
        return scenePhase == .active && authSession.isLoggedIn
            && (status == .standby || status == .unknown)
            && tabRouter.selectedTab == .glasses && pairingCoordinator.path.isEmpty
            && showsTabBar && !tabRouter.hidesTabBarForImmersiveCover
            && !pairingCoordinator.showSearchingSheet
            && !pairingCoordinator.userConfirmedPairingDevice && !pairingCoordinator.isBindingDevice
            && !importManager.isImporting && !recordingImportManager.isImporting
            && !bluetoothOtaUpgradeManager.isUpgrading && !bluetoothOtaUpgradeManager.state.isTerminal
            && deviceUpgradeSheet == nil
    }

    /// Includes readiness so a deferred offer is reconsidered after pairing/navigation.
    private struct DeviceUpdatePromptEvaluation: Equatable {
        let bluetooth: DeviceFirmwareUpdateCoordinator.UpdateOffer?
        let firmware: DeviceFirmwareUpdateCoordinator.UpdateOffer?
        let readiness: String
    }

    private var deviceUpdatePromptEvaluationKey: DeviceUpdatePromptEvaluation {
        let ble = pairingCoordinator.astraA1BleManager
        let readiness = [
            "\(canPresentDeviceUpdate)", "\(showsGen1RecoveryPrompt)",
            ble.deviceBluetoothIdentifier ?? "", "\(ble.isDeviceAvailable)",
            "\(ble.isQueryingDeviceVersionsAndStorage || ble.isQueryingAboutDeviceInfo)",
            "\(ble.deviceVersionQueryFailed)", ble.deviceVersion2800 ?? "", ble.deviceVersion6350 ?? ""
        ].joined(separator: "|")
        return DeviceUpdatePromptEvaluation(
            bluetooth: deviceFirmwareUpdateCoordinator.bluetoothUpdate,
            firmware: deviceFirmwareUpdateCoordinator.firmwareUpdate,
            readiness: readiness
        )
    }

    private func isCurrentOrdinaryOffer(_ presentation: DeviceUpdatePresentation) -> Bool {
        let ble = pairingCoordinator.astraA1BleManager
        guard ble.isDeviceAvailable, !ble.deviceVersionQueryFailed,
              !presentation.offer.isGen1BluetoothRecovery,
              ble.matchesCurrentDevice(serialNumber: presentation.offer.serialNumber,
                                       hardwareSN: presentation.offer.serialNumber) else { return false }
        let latest = presentation.kind == .bluetooth
            ? deviceFirmwareUpdateCoordinator.bluetoothUpdate : deviceFirmwareUpdateCoordinator.firmwareUpdate
        let currentVersion = presentation.kind == .bluetooth ? ble.deviceVersion2800 : ble.deviceVersion6350
        return latest == presentation.offer && currentVersion == presentation.offer.currentVersion
    }

    @MainActor
    private func showDeviceUpdatePromptIfNeeded() async {
        if deviceFirmwareUpdateCoordinator.bluetoothUpdate?.isGen1BluetoothRecovery == true {
            deviceUpdatePrompt = nil
            showGen1RecoveryPromptIfNeeded()
            return
        }
        if let presented = deviceUpdatePrompt {
            if !isCurrentOrdinaryOffer(presented) {
                deviceUpdatePrompt = nil
            } else if !canPresentDeviceUpdate {
                deviceUpdatePrompt = nil
                didShowDeviceUpdateThisSession = false
            }
            return
        }
        guard !didShowDeviceUpdateThisSession, canPresentDeviceUpdate,
              !showsGen1RecoveryPrompt else { return }
        let presentation: DeviceUpdatePresentation
        if let offer = deviceFirmwareUpdateCoordinator.bluetoothUpdate {
            presentation = DeviceUpdatePresentation(kind: .bluetooth, offer: offer)
        } else if let offer = deviceFirmwareUpdateCoordinator.firmwareUpdate {
            presentation = DeviceUpdatePresentation(kind: .firmware, offer: offer)
        } else { return }
        let ble = pairingCoordinator.astraA1BleManager
        guard !ble.isQueryingDeviceVersionsAndStorage, !ble.isQueryingAboutDeviceInfo,
              isCurrentOrdinaryOffer(presentation) else { return }

        // Wait for transient home sheets/alerts to close before counting the prompt as shown.
        // This task is cancelled when the target, offer or navigation readiness changes.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, canPresentDeviceUpdate, isCurrentOrdinaryOffer(presentation),
                  !showsGen1RecoveryPrompt else { return }
            let root = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
            guard let root, root.presentedViewController == nil else { continue }
            didShowDeviceUpdateThisSession = true
            deviceUpdatePrompt = presentation
            return
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tabRouter.selectedTab {
        case .glasses:
            HomeView(showsTabBar: $showsTabBar)
        case .ai:
            AIChatView(
                visionTransfer: aiVisionTransfer,
                showsTabBar: $showsTabBar,
                token: authSession.token
            )
        case .album:
            AlbumView(showsTabBar: $showsTabBar)
        case .profile:
            ProfileView(showsTabBar: $showsTabBar)
        }
    }

    private var customTabBar: some View {
        HStack {
            ForEach(TabItem.allCases, id: \.rawValue) { tab in
                Button {
                    tabRouter.selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(tabRouter.selectedTab == tab ? tab.selectedIconName : tab.iconName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 48, height: 48)

                        Text(tab.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(tabRouter.selectedTab == tab ? AppTheme.accent : AppTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AppTheme.cardBackground)
                .shadow(color: AppTheme.cardShadow, radius: 8, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

extension View {
    /// Apply only to a navigation root, never to its NavigationStack or destinations.
    func mainTabRootContent(reservesTabBar: Bool = true) -> some View {
        padding(.bottom, reservesTabBar ? TabBarLayout.contentInset : 0)
    }
}

private struct PlaceholderTabView: View {
    let title: String

    var body: some View {
        VStack {
            Spacer()
            Text(title)
                .font(.title2)
                .foregroundStyle(AppTheme.secondaryText)
            Spacer()
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthSession())
        .environmentObject(PairingCoordinator())
}
