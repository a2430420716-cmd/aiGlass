import SwiftUI

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
        case .album: L10n.t("相册", "Album")
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

private enum TabBarLayout {
    static let contentInset: CGFloat = 88
}

struct MainTabView: View {
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

    /// 眼镜 Tab 内 push / 沉浸页：立即收起 TabBar 与底部 inset，避免过渡层底部留白。
    private var hidesTabBarForNavigation: Bool {
        (tabRouter.selectedTab == .glasses && !pairingCoordinator.path.isEmpty)
            || tabRouter.hidesTabBarForImmersiveCover
    }

    private var bottomInset: CGFloat {
        showsTabBar && !hidesTabBarForNavigation ? TabBarLayout.contentInset : 0
    }

    private var showsTabBarChrome: Bool {
        showsTabBar && !hidesTabBarForNavigation
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AppTheme.background
                .ignoresSafeArea()

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, bottomInset)
                .id(languageManager.refreshID)

            customTabBar
                .opacity(showsTabBarChrome ? 1 : 0)
                .offset(y: showsTabBarChrome ? 0 : TabBarLayout.contentInset)
                .allowsHitTesting(showsTabBarChrome)
                .accessibilityHidden(!showsTabBarChrome)
        }
        .background(AppTheme.background.ignoresSafeArea())
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
        .onChangeCompat(of: authSession.userInfo?.bluetoothBySerialNumber.count ?? 0) { _ in
            scheduleFirmwareUpdateRefresh()
        }
        .onChangeCompat(of: authSession.userInfo?.firmwareBySerialNumber.count ?? 0) { _ in
            scheduleFirmwareUpdateRefresh()
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.isDeviceAvailable) { available in
            updateAudioConnectionState(available)
            if !available {
                aiVoiceChat.resetAfterDisconnect()
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
        .onChangeCompat(of: bluetoothOtaUpgradeManager.state) { newState in
            if case .completed = newState {
                Task { await authSession.refreshUserInfo() }
                scheduleFirmwareUpdateRefresh()
            }
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
            AppTheme.cardBackground
                .shadow(color: AppTheme.cardShadow, radius: 8, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
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
