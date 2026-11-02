import Combine
import SwiftUI

struct GlassesSettingsView: View {
    let device: DeviceCardData?
    let suppressesTabBarOnAppear: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var pairingCoordinator: PairingCoordinator
    @EnvironmentObject private var updateCoordinator: DeviceFirmwareUpdateCoordinator
    @EnvironmentObject private var otaManager: BluetoothOtaUpgradeManager
    @EnvironmentObject private var tabRouter: MainTabRouter
    @State private var sleepWhenRemoved = true
    @State private var imageWatermarkEnabled = false
    @State private var selectedWatermarkStyle = 2
    @State private var autoSave = false
    @State private var voiceWakeUpState = VoiceWakeupSettingState()
    @State private var isSettingsVisible = false
    @State private var listeningDurationSeconds = 10
    @State private var pendingListeningDurationSeconds: Int?
    @State private var recordDurationSeconds = DeviceMediaSettings.defaultRecordDurationSeconds
    @State private var videoResolutionProfile = DeviceMediaSettings.defaultVideoResolution
    @State private var showRecordDurationOptions = false
    @State private var showVideoResolutionOptions = false
    @State private var showAIVisionOptions = false
    @State private var showListeningDurationOptions = false
    @State private var showFactoryResetConfirmation = false
    @State private var showFactoryResetGuide = false
    @State private var showUnpairConfirmation = false
    @State private var showConnectBeforeUnpair = false
    @State private var showForceUnpairConfirmation = false
    @State private var isUnpairing = false
    @State private var unpairErrorMessage: String?
    @State private var showUnpairSuccess = false
    @State private var navigateToNewbieGuide = false
    @State private var guideAlertMessage: String?
    @State private var autoSaveAlertMessage: String?

    init(device: DeviceCardData? = nil, suppressesTabBarOnAppear: Bool = true) {
        self.device = device
        self.suppressesTabBarOnAppear = suppressesTabBarOnAppear
    }

    private var boundDevice: UserDevice? {
        let devices = authSession.userInfo?.device ?? []
        if let serial = normalized(device?.serialNumber),
           let match = devices.first(where: { normalized($0.serialNumber) == serial }) {
            return match
        }
        if let hardwareSN = normalized(device?.hardwareSN),
           let match = devices.first(where: { normalized($0.hardwareSN) == hardwareSN }) {
            return match
        }
        if device != nil { return nil }
        return devices.first
    }

    private var targetSerialNumber: String? {
        nonEmpty(device?.serialNumber) ?? nonEmpty(boundDevice?.serialNumber)
    }

    private var targetHardwareSN: String? {
        nonEmpty(device?.hardwareSN) ?? nonEmpty(boundDevice?.hardwareSN)
    }

    private var watermarkStyles: [WatermarkStyleItem] {
        [
            WatermarkStyleItem(id: 1, name: L10n.t("样式1", "Style 1"), imageName: "watermark_style_1", width: 81, height: 87),
            WatermarkStyleItem(id: 2, name: L10n.t("样式2", "Style 2"), imageName: "watermark_style_2", width: 81, height: 102),
            WatermarkStyleItem(id: 3, name: L10n.t("样式3", "Style 3"), imageName: "watermark_style_3", width: 81, height: 107)
        ]
    }

    private var guideModelName: String {
        if let model = boundDevice?.modelName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            return model
        }
        return pairingCoordinator.selectedAPIModelName
            ?? (pairingCoordinator.astraA1BleManager.deviceGeneration == .gen1G5K61 ? "G5K61" : "G5T71")
    }

    private var mediaSettingsDeviceKey: String? {
        let ble = pairingCoordinator.astraA1BleManager
        if let serial = targetSerialNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty {
            return serial
        }
        if let bluetoothID = ble.deviceBluetoothIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bluetoothID.isEmpty {
            return bluetoothID
        }
        return ble.deviceSN
    }

    /// 未连接时设置项置灰，仅「解除配对」可点。
    private var isGlassesConnected: Bool {
        let ble = pairingCoordinator.astraA1BleManager
        return ble.isDeviceAvailable && boundDevice != nil
            && ble.matchesCurrentDevice(serialNumber: targetSerialNumber, hardwareSN: targetHardwareSN)
    }

    private func showsCapability(_ capability: KeyPath<DeviceCapabilities, Bool>) -> Bool {
        let ble = pairingCoordinator.astraA1BleManager
        return !isGlassesConnected || ble.deviceGeneration == .unknown
            || ble.deviceCapabilities[keyPath: capability]
    }

    private var supportedRecordDurations: [Int] {
        pairingCoordinator.astraA1BleManager.deviceCapabilities.recordDurationSeconds.filter { $0 != 600 }
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    generalSection
                        .disabled(!isGlassesConnected)
                        .opacity(isGlassesConnected ? 1 : 0.45)
                    photoVideoSection
                        .disabled(!isGlassesConnected)
                        .opacity(isGlassesConnected ? 1 : 0.45)
                    aiAssistantSection
                        .disabled(!isGlassesConnected)
                        .opacity(isGlassesConnected ? 1 : 0.45)
                    otherSection
                        .disabled(!isGlassesConnected)
                        .opacity(isGlassesConnected ? 1 : 0.45)

                    unpairButton
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .overlay {
            if pairingCoordinator.isWaitingForUnpairFactoryReset { UnpairFactoryResetProgressView() }
        }
        .navigationBarHidden(true)
        .suppressTabBarOnAppear(enabled: suppressesTabBarOnAppear)
        .onAppear {
            isSettingsVisible = true
            voiceWakeUpState.reset()
            imageWatermarkEnabled = AppSettings.imageWatermarkEnabled
            selectedWatermarkStyle = AppSettings.imageWatermarkStyle
            autoSave = DeviceMediaSettings.isAutoSaveEnabled(
                userId: authSession.phoneNumber,
                deviceKey: mediaSettingsDeviceKey
            )
            recordDurationSeconds = DeviceMediaSettings.recordDurationSeconds(
                userId: authSession.phoneNumber,
                deviceKey: mediaSettingsDeviceKey
            )
            videoResolutionProfile = DeviceMediaSettings.videoResolution(
                userId: authSession.phoneNumber,
                deviceKey: mediaSettingsDeviceKey
            )
            sleepWhenRemoved = DeviceMediaSettings.isWearDetectionEnabled(
                userId: authSession.phoneNumber,
                deviceKey: mediaSettingsDeviceKey
            )
            if let seconds = pairingCoordinator.astraA1BleManager.settingsRecordDurationSeconds,
               isGlassesConnected, supportedRecordDurations.contains(seconds) {
                recordDurationSeconds = seconds
            }
            if isGlassesConnected,
               let response = pairingCoordinator.astraA1BleManager.aiVoiceListeningDurationResponse {
                listeningDurationSeconds = response.seconds
            }
            pairingCoordinator.astraA1BleManager.ensureConnected(reason: "settings")
            queryDocumentedSettings()
            updateCoordinator.refreshAvailability(
                authSession: authSession,
                ble: pairingCoordinator.astraA1BleManager,
                otaManager: otaManager
            )
        }
        .onChangeCompat(of: imageWatermarkEnabled) { enabled in
            AppSettings.imageWatermarkEnabled = enabled
        }
        .onChangeCompat(of: selectedWatermarkStyle) { style in
            AppSettings.imageWatermarkStyle = style
            // 点选样式时自动打开水印开关，避免选了却没开。
            if !imageWatermarkEnabled {
                imageWatermarkEnabled = true
            }
        }
        .onChangeCompat(of: isGlassesConnected) { ready in
            if ready {
                queryDocumentedSettings()
            } else {
                voiceWakeUpState.reset()
                pendingListeningDurationSeconds = nil
            }
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.deviceBluetoothIdentifier) { _ in
            voiceWakeUpState.reset()
            if isSettingsVisible { queryDocumentedSettings() }
        }
        .onChangeCompat(of: scenePhase) { phase in
            guard phase == .active, isSettingsVisible, !voiceWakeUpState.isSetting else { return }
            refreshVoiceWakeUpState()
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.aiVoiceListeningDurationResponse) { response in
            guard let response, isGlassesConnected else { return }
            handleAIVoiceListeningDurationResponse(response)
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.voiceWakeupResponse) { response in
            guard let response, isSettingsVisible, isGlassesConnected else { return }
            handleVoiceWakeupResponse(response)
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.settingsRecordDurationSeconds) { seconds in
            guard let seconds, isGlassesConnected, supportedRecordDurations.contains(seconds) else { return }
            recordDurationSeconds = seconds
            DeviceMediaSettings.setRecordDurationSeconds(
                seconds,
                userId: authSession.phoneNumber,
                deviceKey: mediaSettingsDeviceKey
            )
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.settingsVideoResolutionProfile) { profile in
            guard let profile, isGlassesConnected else { return }
            videoResolutionProfile = profile
            DeviceMediaSettings.setVideoResolution(
                profile,
                userId: authSession.phoneNumber,
                deviceKey: mediaSettingsDeviceKey
            )
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.settingsWearDetectionEnabled) { enabled in
            guard let enabled, isGlassesConnected else { return }
            sleepWhenRemoved = enabled
            DeviceMediaSettings.setWearDetectionEnabled(
                enabled,
                userId: authSession.phoneNumber,
                deviceKey: mediaSettingsDeviceKey
            )
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.factoryResetResult) { result in
            guard let result else { return }
            switch result {
            case 1:
                guideAlertMessage = L10n.t("恢复出厂设置成功", "Factory reset successful")
            case 2:
                guideAlertMessage = L10n.t("正在恢复出厂设置", "Factory reset in progress")
            default:
                guideAlertMessage = L10n.t("恢复出厂设置失败", "Factory reset failed")
            }
        }
        .onDisappear {
            isSettingsVisible = false
            voiceWakeUpState.reset()
        }
        .confirmationDialog(
            L10n.t("短视频时间长度", "Short Video Length"),
            isPresented: $showRecordDurationOptions,
            titleVisibility: .visible
        ) {
            ForEach(supportedRecordDurations, id: \.self) { seconds in
                Button(recordDurationTitle(seconds)) {
                    applyRecordDuration(seconds)
                }
            }
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.t("视频分辨率", "Video Resolution"),
            isPresented: $showVideoResolutionOptions,
            titleVisibility: .visible
        ) {
            Button("2K") { applyVideoResolution(2) }
            Button("1080p") { applyVideoResolution(1) }
            Button("720p") { applyVideoResolution(0) }
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.t("智能识别模式", "Smart Recognition Mode"),
            isPresented: $showAIVisionOptions,
            titleVisibility: .visible
        ) {
            ForEach(AiVisionSettings.Level.allCases) { level in
                Button(level.title) { applyAIVisionLevel(level.rawValue) }
            }
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.t("连续对话时长", "Continuous Conversation Duration"),
            isPresented: $showListeningDurationOptions,
            titleVisibility: .visible
        ) {
            ForEach([10, 20, 30], id: \.self) { seconds in
                Button(listeningDurationOptionTitle(seconds)) {
                    applyListeningDuration(seconds)
                }
            }
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        }
        .alert(L10n.t("恢复出厂设置", "Factory Reset"), isPresented: $showFactoryResetConfirmation) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("确认恢复", "Confirm Reset"), role: .destructive) {
                sendFactoryResetCommand()
            }
        } message: {
            Text(L10n.t(
                "该操作将清除眼镜中未导入的照片、视频及音频数据，建议先将媒体文件导入至手机进行备份。是否确认继续恢复出厂设置？",
                "This will erase photos, videos, and audio files not yet imported from the glasses. Back up media first. Continue?"
            ))
        }
        .alert(L10n.t("恢复出厂设置", "Factory Reset"), isPresented: $showFactoryResetGuide) {
            Button(L10n.t("知道了", "Got It"), role: .cancel) {}
        } message: {
            Text(L10n.t(
                "第一步：连续短按3次电源键，内侧绿色指示灯连续闪烁\n\n第二步：再连续短按3次拍摄按钮，内侧白色指示灯连续闪烁\n\n完成后蓝色指示灯闪烁，进入配对状态",
                "Step 1: Quickly press the power button 3 times until the inner green indicator flashes.\n\nStep 2: Quickly press the capture button 3 times until the inner white indicator flashes.\n\nWhen complete, the blue indicator flashes and the glasses enter pairing mode."
            ))
        }
        .alert(unpairConfirmationTitle, isPresented: $showUnpairConfirmation) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("确认解绑", "Confirm unpair"), role: .destructive) {
                checkDeviceConnectionBeforeUnpair()
            }
        } message: {
            Text(L10n.t(
                "解除配对后，眼镜端的所有数据将被清空且无法恢复，是否继续？",
                "Unpairing will erase all data on the glasses permanently. Do you want to continue?"
            ))
        }
        .alert(L10n.t("解绑前，请先连接设备", "Connect the device before unbinding"), isPresented: $showConnectBeforeUnpair) {
            Button(L10n.t("无法连接", "Cannot connect"), role: .cancel) {
                showForceUnpairConfirmation = true
            }
            Button(L10n.t("去连接", "Connect")) {
                dismiss()
            }
        }
        .alert(forceUnpairTitle, isPresented: $showForceUnpairConfirmation) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("强制解绑", "Force unbind"), role: .destructive) {
                performUnpair(force: true)
            }
        } message: {
            Text(L10n.t(
                "设备未连接状态下，强制解绑无法清空数据，存在数据泄露风险，请谨慎操作。",
                "When the device is offline, force unbinding cannot clear its data and may expose data. Please proceed carefully."
            ))
        }
        .alert(L10n.t("解除配对失败", "Unpair Failed"), isPresented: Binding(
            get: { unpairErrorMessage != nil },
            set: { if !$0 { unpairErrorMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(unpairErrorMessage ?? "")
        }
        .alert(L10n.t("解除配对成功", "Unpaired"), isPresented: $showUnpairSuccess) {
            Button(L10n.t("确定", "OK"), role: .cancel) {
                dismiss()
            }
        } message: {
            Text(L10n.t("账号绑定已解除。如需彻底移除蓝牙连接，请前往 iPhone「设置 > 蓝牙」，找到眼镜设备，点击设备右侧的 ⓘ，选择「忽略此设备」。", "Account binding removed. To fully remove Bluetooth, go to iPhone Settings > Bluetooth, find the glasses, tap ⓘ, then Forget This Device."))
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { guideAlertMessage != nil },
            set: { if !$0 { guideAlertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(guideAlertMessage ?? "")
        }
        .alert(L10n.t("自动保存", "Auto-Save"), isPresented: Binding(
            get: { autoSaveAlertMessage != nil },
            set: { if !$0 { autoSaveAlertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(autoSaveAlertMessage ?? "")
        }
        .onChangeCompat(of: navigateToNewbieGuide) { active in
            if !active {
                tabRouter.endImmersiveCover()
                tabRouter.setBlackNavigationBackdrop(false)
            }
        }
    }

    private func openNewbieGuide() {
        guard isGlassesConnected else {
            guideAlertMessage = L10n.t("请先连接眼镜", "Please connect your glasses first")
            return
        }
        guard !navigateToNewbieGuide else { return }
        tabRouter.performPushAfterReleasingTabInset(blackBackdrop: true) {
            guard isGlassesConnected else { return }
            navigateToNewbieGuide = true
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("眼镜设置", "Glasses Settings"))
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

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: L10n.t("通用", "General"))

            SettingsCard {
                if showsCapability(\.wearingDetection) {
                    SettingsToggleRow(
                        title: L10n.t("摘下休眠", "Sleep When Removed"),
                        subtitle: L10n.t("开启后，摘下眼镜进入休眠状态，摘下后 180 秒进入休眠", "When on, glasses sleep after removal. Sleep starts 180 seconds after removal."),
                        isOn: Binding(
                            get: { sleepWhenRemoved },
                            set: { applyWearDetection($0) }
                        )
                    )
                }
            }
        }
    }

    private var photoVideoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: L10n.t("照片和视频", "Photos & Videos"))

            SettingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsToggleRow(
                        title: L10n.t("选择图片水印样式", "Photo Watermark Style"),
                        isOn: $imageWatermarkEnabled,
                        showsDivider: false
                    )

                    HStack(alignment: .top, spacing: 10) {
                        ForEach(watermarkStyles) { style in
                            WatermarkStyleOptionView(
                                title: style.name,
                                imageName: style.imageName,
                                width: style.width,
                                height: style.height,
                                isSelected: selectedWatermarkStyle == style.id
                            ) {
                                selectedWatermarkStyle = style.id
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .padding(.vertical, 4)

                SettingsDivider()
                if showsCapability(\.recordDuration) {
                    SettingsNavigationRow(
                        title: L10n.t("短视频时间长度", "Short Video Length"),
                        value: recordDurationTitle(recordDurationSeconds),
                        subtitle: L10n.t("设置视频录制时长，达到设定时间后自动停止", "Set recording duration; recording stops automatically at the limit"),
                        action: { showRecordDurationOptions = true }
                    )
                    SettingsDivider()
                }
                if showsCapability(\.videoResolution) {
                    SettingsNavigationRow(
                        title: L10n.t("视频分辨率", "Video Resolution"),
                        value: videoResolutionTitle,
                        action: { showVideoResolutionOptions = true }
                    )
                    SettingsDivider()
                }
                SettingsToggleRow(
                    title: L10n.t("自动保存", "Auto-Save"),
                    subtitle: L10n.t("照片和视频同步到 APP 后，自动保存到手机系统相册", "Automatically save synced photos and videos to the system Photos app"),
                    isOn: Binding(
                        get: { autoSave },
                        set: { updateAutoSave($0) }
                    )
                )
            }
        }
    }

    private func updateAutoSave(_ enabled: Bool) {
        guard isGlassesConnected else { return }
        guard mediaSettingsDeviceKey != nil else {
            autoSave = false
            autoSaveAlertMessage = L10n.t("请先绑定眼镜设备", "Please bind your glasses first")
            return
        }

        autoSave = enabled
        if !enabled {
            DeviceMediaSettings.setAutoSaveEnabled(
                false,
                userId: authSession.phoneNumber,
                deviceKey: mediaSettingsDeviceKey
            )
            return
        }

        Task {
            let granted = await SystemPhotoLibrarySaver.requestAddAuthorization()
            guard isGlassesConnected else {
                autoSave = false
                return
            }
            if granted {
                DeviceMediaSettings.setAutoSaveEnabled(
                    true,
                    userId: authSession.phoneNumber,
                    deviceKey: mediaSettingsDeviceKey
                )
            } else {
                autoSave = false
                DeviceMediaSettings.setAutoSaveEnabled(
                    false,
                    userId: authSession.phoneNumber,
                    deviceKey: mediaSettingsDeviceKey
                )
                autoSaveAlertMessage = L10n.t("未获得相册添加权限，请前往 iPhone「设置 > AIGlass > 照片」允许添加照片。", "Photos add permission denied. Go to iPhone Settings > AIGlass > Photos and allow adding photos.")
            }
        }
    }

    private func queryDocumentedSettings() {
        guard isGlassesConnected else { return }
        let ble = pairingCoordinator.astraA1BleManager
        if ble.deviceCapabilities.videoResolution { _ = ble.queryVideoResolution() }
        if ble.deviceCapabilities.wearingDetection { _ = ble.queryWearDetection() }
        if ble.deviceCapabilities.aiImageRecognition { _ = ble.syncAIVisionLevel(AiVisionSettings.level) }
        if ble.deviceCapabilities.voiceWakeupSetting {
            _ = ble.queryAIVoiceListeningDuration()
            refreshVoiceWakeUpState()
        }
        if ble.deviceCapabilities.recordDuration { _ = ble.queryRecordDuration() }
    }

    private func recordDurationTitle(_ seconds: Int) -> String {
        if seconds < 60 {
            return L10n.t("\(seconds)秒", "\(seconds)s")
        }
        let minutes = seconds / 60
        return L10n.t("\(minutes)分钟", "\(minutes) min")
    }

    private var videoResolutionTitle: String {
        switch videoResolutionProfile {
        case 0: return "720p"
        case 1: return "1080p"
        default: return "2K"
        }
    }

    private func applyRecordDuration(_ seconds: Int) {
        guard isGlassesConnected, supportedRecordDurations.contains(seconds),
              pairingCoordinator.astraA1BleManager.deviceCapabilities.recordDuration else { return }
        recordDurationSeconds = seconds
        DeviceMediaSettings.setRecordDurationSeconds(
            seconds,
            userId: authSession.phoneNumber,
            deviceKey: mediaSettingsDeviceKey
        )

        let ble = pairingCoordinator.astraA1BleManager
        guard ble.deviceRuntimeStatus == .standby || ble.deviceRuntimeStatus == .unknown else {
            guideAlertMessage = ble.deviceRuntimeStatus.busyMessage
            return
        }
        guideAlertMessage = ble.setRecordTime(seconds: seconds)
            ? L10n.t("录像时长设置成功", "Video duration set")
            : L10n.t("录像时长设置失败", "Failed to set video duration")
    }

    private func applyVideoResolution(_ profile: UInt8) {
        let ble = pairingCoordinator.astraA1BleManager
        guard isGlassesConnected, ble.deviceCapabilities.videoResolution else { return }
        guard ble.deviceRuntimeStatus == .standby || ble.deviceRuntimeStatus == .unknown else {
            guideAlertMessage = ble.deviceRuntimeStatus.busyMessage
            return
        }

        let oldProfile = videoResolutionProfile
        videoResolutionProfile = min(profile, 2)
        DeviceMediaSettings.setVideoResolution(
            videoResolutionProfile,
            userId: authSession.phoneNumber,
            deviceKey: mediaSettingsDeviceKey
        )
        guard ble.setVideoResolution(profile: videoResolutionProfile) else {
            videoResolutionProfile = oldProfile
            DeviceMediaSettings.setVideoResolution(
                oldProfile,
                userId: authSession.phoneNumber,
                deviceKey: mediaSettingsDeviceKey
            )
            guideAlertMessage = L10n.t("视频分辨率设置失败", "Failed to set video resolution")
            return
        }
        guideAlertMessage = L10n.t("视频分辨率设置成功", "Video resolution set")
    }

    private func applyWearDetection(_ enabled: Bool) {
        guard isGlassesConnected else { return }
        let oldValue = sleepWhenRemoved
        sleepWhenRemoved = enabled
        DeviceMediaSettings.setWearDetectionEnabled(
            enabled,
            userId: authSession.phoneNumber,
            deviceKey: mediaSettingsDeviceKey
        )
        guard pairingCoordinator.astraA1BleManager.setWearDetection(enabled: enabled) else {
            sleepWhenRemoved = oldValue
            DeviceMediaSettings.setWearDetectionEnabled(
                oldValue,
                userId: authSession.phoneNumber,
                deviceKey: mediaSettingsDeviceKey
            )
            guideAlertMessage = L10n.t("摘下休眠设置失败", "Failed to set wear detection")
            return
        }
    }

    private func applyAIVisionLevel(_ level: UInt8) {
        guard isGlassesConnected else { return }
        AiVisionSettings.level = level
        if pairingCoordinator.astraA1BleManager.syncAIVisionLevel(level) {
            guideAlertMessage = L10n.t("智能识别模式已保存", "Recognition mode saved")
        } else {
            guideAlertMessage = L10n.t("智能识别模式同步失败", "Failed to sync recognition mode")
        }
    }

    private func prepareFactoryReset() {
        let ble = pairingCoordinator.astraA1BleManager
        guard isGlassesConnected else {
            guideAlertMessage = L10n.t("请先连接眼镜", "Please connect your glasses first")
            return
        }
        guard ble.deviceRuntimeStatus == .standby || ble.deviceRuntimeStatus == .unknown else {
            guideAlertMessage = ble.deviceRuntimeStatus.busyMessage
            return
        }
        showFactoryResetConfirmation = true
    }

    private func sendFactoryResetCommand() {
        guard isGlassesConnected else {
            guideAlertMessage = L10n.t("请先连接已绑定的眼镜", "Please connect your bound glasses first")
            return
        }
        guard pairingCoordinator.astraA1BleManager.factoryResetDevice() else {
            guideAlertMessage = L10n.t("恢复出厂设置失败", "Factory reset failed")
            return
        }
        showFactoryResetGuide = true
    }

    private func updateVoiceWakeUp(_ enabled: Bool) {
        let ble = pairingCoordinator.astraA1BleManager
        guard isSettingsVisible, isGlassesConnected, ble.deviceCapabilities.voiceWakeupSetting,
              let generation = voiceWakeUpState.beginSet(enabled) else { return }
        sendVoiceWakeUpCommand(enabled, generation: generation, allowRetry: true)
    }

    private func isCurrentVoiceWakeUpRequest(_ generation: Int, peripheralID: String?) -> Bool {
        isSettingsVisible && isGlassesConnected
            && pairingCoordinator.astraA1BleManager.deviceCapabilities.voiceWakeupSetting
            && pairingCoordinator.astraA1BleManager.deviceBluetoothIdentifier == peripheralID
            && voiceWakeUpState.generation == generation
    }

    private func sendVoiceWakeUpCommand(_ enabled: Bool, generation: Int, allowRetry: Bool) {
        let ble = pairingCoordinator.astraA1BleManager
        let peripheralID = ble.deviceBluetoothIdentifier
        guard isCurrentVoiceWakeUpRequest(generation, peripheralID: peripheralID) else { return }
        let sent = ble.setVoiceWakeupEnabled(enabled)
        print("[VoiceWakeup] set enabled=\(enabled) sent=\(sent) retry=\(allowRetry)")
        if sent {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard isCurrentVoiceWakeUpRequest(generation, peripheralID: peripheralID),
                      voiceWakeUpState.setTimedOut(generation: generation) else { return }
                guideAlertMessage = L10n.t("语音唤醒设置失败", "Failed to set voice wake-up")
                scheduleVoiceWakeUpQuery(delay: 0.25)
            }
        } else if allowRetry {
            // Retry only when the transport did not enqueue the write.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                guard isCurrentVoiceWakeUpRequest(generation, peripheralID: peripheralID) else { return }
                sendVoiceWakeUpCommand(enabled, generation: generation, allowRetry: false)
            }
        } else if voiceWakeUpState.sendFailed(generation: generation) {
            guideAlertMessage = L10n.t("语音唤醒设置失败", "Failed to set voice wake-up")
        }
    }

    private func refreshVoiceWakeUpState() {
        let ble = pairingCoordinator.astraA1BleManager
        guard isSettingsVisible, isGlassesConnected, ble.deviceCapabilities.voiceWakeupSetting,
              !voiceWakeUpState.isSetting else { return }
        voiceWakeUpState.reset()
        scheduleVoiceWakeUpQuery()
    }

    private func scheduleVoiceWakeUpQuery(delay: TimeInterval = 0.8) {
        let ble = pairingCoordinator.astraA1BleManager
        guard isSettingsVisible, isGlassesConnected, ble.deviceCapabilities.voiceWakeupSetting,
              let generation = voiceWakeUpState.beginQuery() else { return }
        let peripheralID = ble.deviceBluetoothIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard isCurrentVoiceWakeUpRequest(generation, peripheralID: peripheralID) else { return }
            let sent = pairingCoordinator.astraA1BleManager.queryVoiceWakeupEnabled()
            print("[VoiceWakeup] query sent=\(sent)")
            if !sent {
                voiceWakeUpState.queryTimedOut(generation: generation)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard isCurrentVoiceWakeUpRequest(generation, peripheralID: peripheralID) else { return }
                voiceWakeUpState.queryTimedOut(generation: generation)
            }
        }
    }

    private func handleVoiceWakeupResponse(_ response: VoiceWakeupResponse) {
        switch voiceWakeUpState.receive(status: response.status, enabled: response.enabled) {
        case .none:
            break
        case .updated:
            guideAlertMessage = L10n.t("语音唤醒设置成功", "Voice wake-up setting updated")
        case .failed(let status):
            switch status {
            case 2:
                guideAlertMessage = L10n.t("设备保存语音唤醒设置失败", "The glasses failed to save the voice wake-up setting")
            case 3:
                guideAlertMessage = L10n.t("设备处理语音唤醒设置失败", "The glasses failed to apply the voice wake-up setting")
            case 4:
                guideAlertMessage = L10n.t("语音唤醒资源缺失，暂时无法开启", "Voice wake-up resources are unavailable")
            default:
                guideAlertMessage = L10n.t("语音唤醒设置失败", "Failed to set voice wake-up")
            }
        }
    }

    @ViewBuilder
    private var voiceWakeUpRow: some View {
        if voiceWakeUpState.phase == .ready || voiceWakeUpState.phase == .setting {
            SettingsToggleRow(
                title: L10n.t("语音唤醒", "Voice Wake"),
                subtitle: L10n.t("开启后，说“Hi MOCO”可唤醒语音助手", "When enabled, say \"Hi MOCO\" to wake the voice assistant"),
                isOn: Binding(
                    get: { voiceWakeUpState.enabled ?? false },
                    set: { updateVoiceWakeUp($0) }
                )
            )
            .disabled(!voiceWakeUpState.canChange)
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("语音唤醒", "Voice Wake"))
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                    Text(!isGlassesConnected
                         ? L10n.t("连接眼镜后读取设备状态", "Connect glasses to read device state")
                         : voiceWakeUpState.phase == .queryFailed
                            ? L10n.t("查询设备状态失败，请重试", "Could not read device state. Retry.")
                            : L10n.t("正在读取设备状态", "Reading device state"))
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 8)
                if voiceWakeUpState.phase == .queryFailed {
                    Button(L10n.t("重试", "Retry"), action: refreshVoiceWakeUpState)
                        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.accent)
                } else if isGlassesConnected {
                    ProgressView()
                } else {
                    Text(L10n.t("未连接", "Disconnected"))
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func applyListeningDuration(_ seconds: Int) {
        guard isGlassesConnected,
              pairingCoordinator.astraA1BleManager.deviceCapabilities.voiceWakeupSetting,
              [10, 20, 30].contains(seconds) else { return }
        pendingListeningDurationSeconds = seconds
        guard pairingCoordinator.astraA1BleManager.setAIVoiceListeningDuration(seconds: seconds) else {
            pendingListeningDurationSeconds = nil
            guideAlertMessage = L10n.t("连续对话时长设置失败", "Failed to set continuous conversation duration")
            return
        }
    }

    private func handleAIVoiceListeningDurationResponse(
        _ response: AIVoiceListeningDurationResponse
    ) {
        let pending = pendingListeningDurationSeconds
        let isSetResponse = pending != nil && (response.status != 0 || response.seconds == pending)
        if isSetResponse {
            pendingListeningDurationSeconds = nil
        }
        listeningDurationSeconds = response.seconds
        guard isSetResponse else { return }

        switch response.status {
        case 0:
            guideAlertMessage = L10n.t("连续对话时长设置成功", "Continuous conversation duration updated")
        case 2:
            guideAlertMessage = L10n.t("设备保存连续对话时长失败", "The glasses failed to save the continuous conversation duration")
        default:
            guideAlertMessage = L10n.t("连续对话时长设置失败", "Failed to set continuous conversation duration")
        }
    }

    private func listeningDurationOptionTitle(_ seconds: Int) -> String {
        L10n.t("\(seconds)秒", "\(seconds) sec")
    }

    private var aiAssistantSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: L10n.t("AI 语音", "AI voice"))

            SettingsCard {
                if showsCapability(\.voiceWakeupSetting) {
                    voiceWakeUpRow
                    SettingsDivider()
                }
                NavigationLink {
                    GlassesVoiceCommandsView(model: GlassDeviceModel(modelName: guideModelName))
                } label: {
                    SettingsNavigationLinkLabel(title: L10n.t("语音指令", "Voice Commands"))
                }
                .buttonStyle(.plain)
                SettingsDivider()
                if showsCapability(\.voiceWakeupSetting) {
                    SettingsNavigationRow(
                        title: L10n.t("连续对话时长", "Continuous conversation duration"),
                        value: listeningDurationOptionTitle(listeningDurationSeconds),
                        subtitle: L10n.t(
                            "对话后 MOCO 将继续聆听一段时间，期间可直接说出下个指令，无需再次唤醒。",
                            "After a conversation, MOCO keeps listening briefly so you can say the next command without waking it again."
                        ),
                        action: { showListeningDurationOptions = true }
                    )
                    .disabled(pendingListeningDurationSeconds != nil)
                    SettingsDivider()
                }
                if showsCapability(\.aiImageRecognition) {
                    SettingsNavigationRow(
                        title: L10n.t("智能识别模式", "Smart Recognition Mode"),
                        value: AiVisionSettings.levelTitle,
                        subtitle: L10n.t("平衡图像识别速度与图像清晰度", "Balance recognition speed and image clarity"),
                        action: { showAIVisionOptions = true }
                    )
                    SettingsDivider()
                }
                SettingsNavigationRow(
                    title: L10n.t("AI语音设置", "AI Voice Settings"),
                    value: L10n.t("眼镜系统语音", "Glasses System Voice"),
                    action: {
                        guideAlertMessage = L10n.t("当前使用眼镜系统语音", "Using glasses system voice")
                    }
                )
            }
        }
    }

    private var otherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: L10n.t("其他", "Other"))

            SettingsCard {
                if GlassDeviceModel(modelName: guideModelName) == .luminaL1 {
                    NavigationLink {
                        Gen1GlassesWifiSettingsView(
                            ble: pairingCoordinator.astraA1BleManager,
                            targetSerialNumber: targetSerialNumber,
                            targetHardwareSN: targetHardwareSN
                        )
                    } label: {
                        SettingsNavigationLinkLabel(title: L10n.t("眼镜Wi-Fi", "Glasses Wi-Fi"))
                    }
                    .buttonStyle(.plain)
                    SettingsDivider()
                }
                NavigationLink {
                    GlassesFirmwareUpgradeView(ble: pairingCoordinator.astraA1BleManager)
                } label: {
                    SettingsNavigationLinkLabel(
                        title: L10n.t("眼镜固件升级", "Glasses Firmware Update"),
                        showsUpdateBadge: updateCoordinator.hasAnyUpdate
                    )
                }
                SettingsDivider()
                Button {
                    openNewbieGuide()
                } label: {
                    SettingsNavigationLinkLabel(title: L10n.t("新手引导", "Getting Started"))
                }
                .buttonStyle(.plain)
                .background {
                    NavigationLink(
                        isActive: $navigateToNewbieGuide,
                        destination: {
                            NewbieGuideView(
                                ble: pairingCoordinator.astraA1BleManager,
                                modelName: guideModelName,
                                token: authSession.token,
                                onClose: { navigateToNewbieGuide = false }
                            )
                        },
                        label: { EmptyView() }
                    )
                    .hidden()
                }
                SettingsDivider()
                NavigationLink {
                    DeviceAboutView(
                        ble: pairingCoordinator.astraA1BleManager,
                        boundSerialNumber: targetSerialNumber
                    )
                        .environmentObject(authSession)
                } label: {
                    SettingsNavigationLinkLabel(title: L10n.t("关于设备", "About Device"))
                }
                SettingsDivider()
                SettingsNavigationRow(
                    title: L10n.t("恢复出厂设置", "Factory Reset"),
                    action: { prepareFactoryReset() }
                )
            }
        }
    }

    private var unpairButton: some View {
        Button {
            showUnpairConfirmation = true
        } label: {
            Group {
                if isUnpairing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(L10n.t("解除配对", "Unpair"))
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color(red: 0.20, green: 0.20, blue: 0.20))
            .clipShape(Capsule())
        }
        .disabled(isUnpairing)
    }

    private var unpairDisplayName: String {
        nonEmpty(device?.name)
            ?? nonEmpty(boundDevice?.displayName)
            ?? nonEmpty(targetSerialNumber)
            ?? "MOCO"
    }

    private var unpairConfirmationTitle: String {
        L10n.t("确认解绑“\(unpairDisplayName)”？", "Unpair \"\(unpairDisplayName)\"?")
    }

    private var forceUnpairTitle: String {
        L10n.t("确认强制解绑“\(unpairDisplayName)”？", "Force unbind \"\(unpairDisplayName)\"?")
    }

    private func checkDeviceConnectionBeforeUnpair() {
        guard targetSerialNumber != nil else {
            unpairErrorMessage = L10n.t("设备未绑定", "Device not bound")
            return
        }
        guard !isUnpairing else { return }

        isUnpairing = true
        Task {
            await authSession.refreshUserInfo()
            if let error = authSession.userInfoError {
                isUnpairing = false
                unpairErrorMessage = error
                return
            }
            guard boundDevice != nil else {
                isUnpairing = false
                unpairErrorMessage = L10n.t("设备未绑定", "Device not bound")
                return
            }

            isUnpairing = false
            if isGlassesConnected {
                performUnpair(force: false)
            } else {
                showConnectBeforeUnpair = true
            }
        }
    }

    private func performUnpair(force: Bool) {
        guard let serialNumber = targetSerialNumber else {
            unpairErrorMessage = L10n.t("未找到已绑定设备", "No bound device found")
            return
        }

        let liveSN = pairingCoordinator.astraA1BleManager.deviceSN?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 眼镜断连时实时 SN 为空，回退配对时落盘的缓存。
        let cachedSN = pairingCoordinator.astraA1BleManager
            .cachedHardwareSN(forSerialNumber: serialNumber)
        let liveTargetSN = isGlassesConnected ? liveSN : nil
        let sn = ([targetHardwareSN, cachedSN, liveTargetSN].compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.first) ?? ""

        guard force || !sn.isEmpty else {
            unpairErrorMessage = L10n.t("未获取到设备 SN，请连接眼镜后重试", "Device SN unavailable. Connect glasses and try again")
            return
        }

        isUnpairing = true
        Task {
            do {
                try await pairingCoordinator.unpairDevice(serialNumber: serialNumber, sn: sn, force: force)
                isUnpairing = false
                showUnpairSuccess = true
            } catch {
                isUnpairing = false
                unpairErrorMessage = error.localizedDescription
            }
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func normalized(_ value: String?) -> String? {
        nonEmpty(value)?.lowercased()
    }
}

private struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AppTheme.notoSansSC(size: 13, weight: .regular))
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.leading, 4)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(Color(red: 0.94, green: 0.94, blue: 0.94))
    }
}

private struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var showsDivider: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)

                if let subtitle {
                    Text(subtitle)
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(AppTheme.accent)
        }
        .padding(.vertical, 12)
    }
}

private struct SettingsNavigationRow: View {
    let title: String
    var value: String?
    var subtitle: String?
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            SettingsNavigationLinkLabel(title: title, value: value, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsNavigationLinkLabel: View {
    let title: String
    var value: String?
    var subtitle: String?
    var showsUpdateBadge: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)

                    if showsUpdateBadge {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.vertical, 12)
    }
}

private struct WatermarkStyleItem: Identifiable {
    let id: Int
    let name: String
    let imageName: String
    let width: CGFloat
    let height: CGFloat
}

private struct WatermarkStyleOptionView: View {
    let title: String
    let imageName: String
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: height)
                    .frame(height: 107, alignment: .top)

                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(isSelected ? AppTheme.accent : Color(red: 0.85, green: 0.85, blue: 0.85), lineWidth: 1.5)
                            .frame(width: 18, height: 18)

                        if isSelected {
                            Circle()
                                .fill(AppTheme.accent)
                                .frame(width: 18, height: 18)

                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                    Text(title)
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    CompatibleNavigationStack {
        GlassesSettingsView()
            .environmentObject(AuthSession())
            .environmentObject(PairingCoordinator())
            .environmentObject(DeviceFirmwareUpdateCoordinator())
            .environmentObject(BluetoothOtaUpgradeManager())
            .environmentObject(MainTabRouter())
    }
}


/// Voice command reference shared with the Android VoiceCommandsActivity screen.
private struct GlassesVoiceCommandsView: View {
    let model: GlassDeviceModel
    @Environment(\.dismiss) private var dismiss

    private struct Command: Identifiable {
        let zh: String
        let en: String
        var unsupportedOnAstra = false
        var id: String { zh }
    }

    private struct Section: Identifiable {
        let zh: String
        let en: String
        let commands: [Command]
        var id: String { zh }
    }

    private var sections: [Section] {
        [
            Section(zh: "唤醒词", en: "Wake Word", commands: [
                Command(zh: "嗨，眸刻/嘿，眸刻", en: "Hi Moco / Hey Moco")
            ]),
            Section(zh: "拍摄指令", en: "Capture Commands", commands: [
                Command(zh: "开始拍照", en: "Take a photo"),
                Command(zh: "开始录像", en: "Take a video")
            ]),
            Section(zh: "播放指令", en: "Playback Commands", commands: [
                Command(zh: "播放音乐", en: "Play music"),
                Command(zh: "停止播放（音乐）", en: "Stop playing", unsupportedOnAstra: true),
                Command(zh: "播放下一曲/下一首", en: "Play next song/track", unsupportedOnAstra: true),
                Command(zh: "播放上一曲/上一首", en: "Play previous song/track", unsupportedOnAstra: true),
                Command(zh: "调高音量/（声音）音量大一点", en: "Volume up"),
                Command(zh: "调低音量/（声音）音量小一点", en: "Volume down")
            ]),
            Section(zh: "通话指令", en: "Call Commands", commands: [
                Command(zh: "接听电话", en: "Answer the phone"),
                Command(zh: "挂断电话", en: "Hang up"),
                Command(zh: "拒接电话", en: "Reject the call", unsupportedOnAstra: true)
            ])
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(L10n.t("语音指令", "Voice Commands"))
                    .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L10n.t(section.zh, section.en))
                                .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(Color.black.opacity(0.04))
                            ForEach(section.commands) { command in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L10n.t(command.zh, command.en))
                                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                                        .fixedSize(horizontal: false, vertical: true)
                                    if model == .astraA1, command.unsupportedOnAstra {
                                        Text(L10n.t("*Astra A1 暂不支持", "*Astra A1 not supported"))
                                            .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                if command.id != section.commands.last?.id {
                                    Divider().padding(.horizontal, 16)
                                }
                            }
                        }
                        .background(AppTheme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .foregroundStyle(AppTheme.primaryText)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
    }
}


/// Configures Gen1's existing router connection; it never starts an OTA update.
private struct Gen1GlassesWifiSettingsView: View {
    @ObservedObject var ble: AstraA1BleManager
    let targetSerialNumber: String?
    let targetHardwareSN: String?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var otaManager: BluetoothOtaUpgradeManager
    @EnvironmentObject private var importManager: MediaImportManager
    @StateObject private var ssidReader = CurrentWifiSSIDReader()
    @State private var ssid = ""
    @State private var password = ""
    @State private var hasEditedSSID = false
    @State private var requestTask: Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var resultMessage: String?
    private var isProvisioning: Bool { requestID != nil }

    private var requiresReconnect: Bool {
        guard !isProvisioning,
              let target = (ble.deviceBluetoothIdentifier ?? targetSerialNumber).flatMap(UUID.init(uuidString:)) else { return false }
        return Gen1WifiProvisionCoordinator.shared.isNetworkOperationBlocked(targetID: target)
    }

    private var isTargetAvailable: Bool {
        ble.deviceGeneration == .gen1G5K61 && ble.isDeviceAvailable
            && ble.matchesCurrentDevice(serialNumber: targetSerialNumber, hardwareSN: targetHardwareSN)
    }

    private var isDeviceIdle: Bool {
        !otaManager.isUpgrading && !ble.isFirmwareUpgradeFlowBusy
            && !ble.isAIVisionTransferBusy && !importManager.isImporting
            && !AIRecordingImportManager.shared.isImporting
            && !ble.isAIRecording && !ble.isVideoRecording && !ble.isTakingPhoto
            && (ble.isDeviceRuntimeIdle || ble.deviceRuntimeStatus == .networkOperating)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(L10n.t("眼镜Wi-Fi", "Glasses Wi-Fi"))
                    .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L10n.t("请输入可上网的 2.4 GHz Wi-Fi 名称与密码。开放网络可不填密码。", "Enter the name and password of a 2.4 GHz Wi-Fi network with internet access. Leave the password empty for an open network."))
                        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 16) {
                        TextField(L10n.t("Wi-Fi 名称（SSID）", "Wi-Fi Name (SSID)"), text: Binding(
                            get: { ssid },
                            set: { value in
                                hasEditedSSID = true
                                ssid = value
                                ssidReader.cancel()
                            }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Divider()
                        SecureField(L10n.t("Wi-Fi 密码", "Wi-Fi Password"), text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(20)
                    .background(AppTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .disabled(isProvisioning)

                    if requiresReconnect {
                        Text(L10n.t("配网结果尚未确认，请先断开并重新连接眼镜，再重试。", "The configuration result is unconfirmed. Disconnect and reconnect your glasses before retrying."))
                            .foregroundStyle(AppTheme.secondaryText)
                            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    } else if !isTargetAvailable || !isDeviceIdle {
                        Text(L10n.t("请连接当前眼镜，并结束拍摄、录音、导入或升级后再配置。", "Connect these glasses and finish any capture, recording, import, or update before configuring Wi-Fi."))
                            .foregroundStyle(AppTheme.secondaryText)
                            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    }
                }
                .padding(20)
            }

            Button(action: configureWifi) {
                HStack(spacing: 8) {
                    if isProvisioning { ProgressView().tint(.white) }
                    Text(isProvisioning ? L10n.t("正在连接", "Connecting") : L10n.t("连接Wi-Fi", "Connect Wi-Fi"))
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isProvisioning || !isTargetAvailable || !isDeviceIdle || requiresReconnect || ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(isTargetAvailable && isDeviceIdle && !requiresReconnect ? 1 : 0.45)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .foregroundStyle(AppTheme.primaryText)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .onAppear {
            ssidReader.start { value in
                guard !hasEditedSSID, !isProvisioning, let value else { return }
                ssid = value
            }
        }
        .onChangeCompat(of: ble.isReady) { ready in
            if !ready { cancelRequest() }
        }
        .onDisappear {
            cancelRequest()
            ssidReader.cancel()
            password = ""
        }
        .alert(L10n.t("眼镜Wi-Fi", "Glasses Wi-Fi"), isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button(L10n.t("知道了", "Got It"), role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private func cancelRequest() {
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
        password = ""
    }

    private func configureWifi() {
        guard isTargetAvailable, isDeviceIdle, !isProvisioning, !requiresReconnect,
              let target = ble.deviceBluetoothIdentifier.flatMap(UUID.init(uuidString:)),
              let account = ble.gen1ImportAccount(for: target) else { return }
        let payload: Data
        do {
            payload = try Gen1FirmwareUpdateProtocol.wifiPayload(ssid: ssid, password: password)
        } catch {
            resultMessage = error.localizedDescription
            return
        }
        ssidReader.cancel()
        let authorization = ble.gen1ImportAuthorizationID
        let coordinator = Gen1WifiProvisionCoordinator.shared
        guard let lease = coordinator.acquire(targetID: target, bootstrapConnected: ble.isReady) else {
            resultMessage = L10n.t("上次配网结果未确认，请断开并重新连接眼镜后再试。", "The previous configuration result is unconfirmed. Disconnect and reconnect your glasses before retrying.")
            return
        }
        let request = UUID()
        requestID = request
        requestTask = Task { @MainActor in
            var wasQueued = false
            var acknowledged = false
            let session = Gen1WifiProvisionSession(
                send: { command, payload in
                    let accepted = ble.sendGen1Command(command: command, payload: payload)
                    wasQueued = accepted
                    return accepted
                },
                validate: {
                    requestID == request && coordinator.isCurrent(lease) && isTargetAvailable && isDeviceIdle
                        && ble.deviceBluetoothIdentifier == target.uuidString
                        && ble.gen1ImportAuthorizationID == authorization
                        && ble.gen1ImportAccount(for: target) == account
                },
                isConnected: { ble.isReady && ble.deviceBluetoothIdentifier == target.uuidString }
            )
            let subscription = ble.gen1ControlSubject.sink { frame in
                session.receive(command: frame.command, payload: frame.payload)
            }
            defer {
                subscription.cancel()
                coordinator.finish(lease, wasQueued: wasQueued, acknowledged: acknowledged)
                if requestID == request {
                    requestID = nil
                    requestTask = nil
                    password = ""
                }
            }
            do {
                try await session.run(payload: payload)
                acknowledged = true
                guard requestID == request else { return }
                resultMessage = L10n.t("Wi-Fi网络配置成功", "Wi-Fi network configured successfully")
            } catch is CancellationError {
                // Leaving the page never turns a queued write into a success message.
            } catch let failure as Gen1WifiProvisionSession.Failure {
                guard requestID == request else { return }
                switch failure {
                case .rejected:
                    acknowledged = true
                    resultMessage = L10n.t("眼镜回复Wi-Fi配置失败，请检查2.4 GHz网络名称与密码。", "The glasses reported a Wi-Fi configuration failure. Check the 2.4 GHz network name and password.")
                case .timedOut, .malformedReply, .unexpectedReply:
                    resultMessage = L10n.t("未能确认眼镜的Wi-Fi配置结果。请重新连接眼镜后再试；这不代表密码错误。", "The glasses' Wi-Fi configuration result could not be confirmed. Reconnect and retry; this does not establish that the password is incorrect.")
                case .sendFailed:
                    resultMessage = L10n.t("配网指令未发送，请重新连接眼镜后再试。", "The configuration command was not sent. Reconnect your glasses and retry.")
                case .unavailable, .disconnected:
                    resultMessage = L10n.t("连接、账号或设备状态已变化，配网结果未确认。", "The connection, account, or device state changed. The configuration result is unconfirmed.")
                }
            } catch {
                guard requestID == request else { return }
                resultMessage = error.localizedDescription
            }
        }
    }
}
