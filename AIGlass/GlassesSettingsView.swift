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
    @State private var showIndicatorBrightnessOptions = false
    @State private var waitingForIndicatorBrightnessOptions = false
    @State private var showVideoResolutionOptions = false
    @State private var showAIVisionOptions = false
    @State private var showListeningDurationOptions = false
    @State private var showFactoryResetConfirmation = false
    @State private var showFactoryResetGuide = false
    @State private var showUnpairConfirmation = false
    @State private var showForceUnpairConfirmation = false
    @State private var showResumeUnpairConfirmation = false
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
        if let match = devices.first(where: {
            pairingCoordinator.astraA1BleManager.matchesCurrentDevice(
                serialNumber: $0.serialNumber, hardwareSN: $0.hardwareSN
            )
        }) {
            return match
        }
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
        let generation = settingsDeviceGeneration
        return generation == .unknown || DeviceCapabilities.forGeneration(generation)[keyPath: capability]
    }

    /// Prefer current account metadata; display names never override a known API type.
    private var settingsDeviceGeneration: DeviceGeneration {
        let type = boundDevice != nil ? boundDevice?.deviceType : device?.deviceType
        if let type { return type.generation }
        let ble = pairingCoordinator.astraA1BleManager
        if isGlassesConnected, ble.deviceGeneration != .unknown {
            return ble.deviceGeneration
        }
        return GlassDeviceModel(modelName: boundDevice?.modelName ?? device?.modelName ?? "").generation
    }

    private var isGen1SettingsDevice: Bool { settingsDeviceGeneration == .gen1G5K61 }

    private var showsIndicatorBrightness: Bool {
        settingsDeviceGeneration == .gen2
    }

    private var indicatorBrightnessSummary: String {
        guard isGlassesConnected else { return L10n.t("未连接", "Not connected") }
        let state = pairingCoordinator.astraA1BleManager.indicatorBrightness
        if let pending = state.pending {
            if case .set = pending.request { return L10n.t("设置中…", "Setting…") }
            return L10n.t("读取中…", "Reading…")
        }
        if let level = state.level { return indicatorBrightnessTitle(level) }
        if state.result?.failure != nil { return L10n.t("暂不可用", "Unavailable") }
        return L10n.t("未读取", "Not read")
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
            if pairingCoordinator.isWaitingForUnpairFactoryReset {
                UnpairFactoryResetProgressView()
            } else if showAIVisionOptions {
                AiVisionModeDialog(
                    selectedLevel: AiVisionSettings.level,
                    onCancel: { showAIVisionOptions = false },
                    onSelect: { level in
                        showAIVisionOptions = false
                        applyAIVisionLevel(level.rawValue)
                    }
                )
            }
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
            DebugLogStore.logWiFi("photo watermark setting", detail: "enabled=\(enabled) style=\(AppSettings.imageWatermarkStyle) source=settings_toggle")
        }
        .onChangeCompat(of: selectedWatermarkStyle) { style in
            AppSettings.imageWatermarkStyle = style
            DebugLogStore.logWiFi("photo watermark setting", detail: "enabled=true style=\(style) source=settings_style")
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
                waitingForIndicatorBrightnessOptions = false
                showIndicatorBrightnessOptions = false
                showAIVisionOptions = false
            }
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.indicatorBrightness.result) { result in
            handleIndicatorBrightnessResult(result)
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.deviceRuntimeStatus) { status in
            if isSettingsVisible, status == .standby {
                queryDocumentedSettings()
            }
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.deviceBluetoothIdentifier) { _ in
            voiceWakeUpState.reset()
            waitingForIndicatorBrightnessOptions = false
            showIndicatorBrightnessOptions = false
            showAIVisionOptions = false
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
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.recordDurationSettingResult) { result in
            guard let result, isSettingsVisible, isGlassesConnected else { return }
            switch result.outcome {
            case .confirmed(let seconds):
                recordDurationSeconds = seconds
                DeviceMediaSettings.setRecordDurationSeconds(seconds, userId: authSession.phoneNumber, deviceKey: mediaSettingsDeviceKey)
                guideAlertMessage = L10n.t("录像时长设置成功", "Recording duration set")
            case .different(_, let actual):
                guideAlertMessage = L10n.t("录像时长未设置成功，眼镜当前为\(recordDurationTitle(actual))，请重试", "Video duration was not applied. Glasses report \(recordDurationTitle(actual)). Please try again.")
            case .unconfirmed:
                guideAlertMessage = L10n.t("未能确认眼镜的录像时长，请重试", "Could not confirm the video duration on your glasses. Please try again.")
            }
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
            waitingForIndicatorBrightnessOptions = false
            showIndicatorBrightnessOptions = false
            showAIVisionOptions = false
        }
        .confirmationDialog(
            L10n.t("指示灯亮度", "Notification LED brightness"),
            isPresented: $showIndicatorBrightnessOptions,
            titleVisibility: .visible
        ) {
            ForEach(IndicatorBrightnessLevel.allCases, id: \.rawValue) { level in
                Button(indicatorBrightnessOptionTitle(level)) {
                    applyIndicatorBrightness(level)
                }
            }
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.t("短视频时间长度", "Video clip duration"),
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
            L10n.t("视频分辨率", "Video resolution"),
            isPresented: $showVideoResolutionOptions,
            titleVisibility: .visible
        ) {
            Button("2K (2016×1512)") { applyVideoResolution(2) }
            Button("1080p (1920×1080)") { applyVideoResolution(1) }
            Button("720p (1280×720)") { applyVideoResolution(0) }
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.t("连续对话时长", "Listening duration"),
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
        .alert(L10n.t("恢复出厂设置", "Factory reset"), isPresented: $showFactoryResetConfirmation) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("确认恢复", "Confirm reset"), role: .destructive) {
                sendFactoryResetCommand()
            }
        } message: {
            Text(L10n.t(
                "该操作将清除眼镜中未导入的照片、视频及音频数据，建议先将媒体文件导入至手机进行备份。是否确认继续恢复出厂设置？",
                "This will erase photos, videos, and audio files that have not been imported from the glasses. We recommend importing media to your phone first. Continue with factory reset?"
            ))
        }
        .alert(L10n.t("恢复出厂设置", "Factory reset"), isPresented: $showFactoryResetGuide) {
            Button(L10n.t("知道了", "Got it"), role: .cancel) {}
        } message: {
            Text(L10n.t(
                "第一步：连续短按3次电源键，内侧绿色指示灯连续闪烁\n\n第二步：再连续短按3次拍摄按钮，内侧白色指示灯连续闪烁\n\n完成后蓝色指示灯闪烁，进入配对状态",
                "Step 1: Quickly press the power button 3 times until the inner green indicator flashes.\n\nStep 2: Quickly press the capture button 3 times until the inner white indicator flashes.\n\nWhen complete, the blue indicator flashes and the glasses enter pairing mode."
            ))
        }
        .alert(unpairConfirmationTitle, isPresented: $showUnpairConfirmation) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("确认解绑", "Confirm unpair"), role: .destructive) {
                performUnpair(force: false)
            }
        } message: {
            Text(L10n.t(
                "解除配对后，眼镜端的所有数据将被清空且无法恢复，是否继续？",
                "Unpairing will erase all data on the glasses permanently. Do you want to continue?"
            ))
        }
        .alert(L10n.t("继续完成解绑", "Complete unpairing"), isPresented: $showResumeUnpairConfirmation) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("继续解绑", "Continue unpairing"), role: .destructive) { performUnpair(force: false) }
        } message: {
            Text(L10n.t("上次账号解绑结果尚未确认。继续操作将先核对服务器状态；已确认重置的眼镜不会重复重置。", "The previous account unbinding is not yet confirmed. Continuing checks the server first; glasses with a confirmed reset will not be reset again."))
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
        .alert(L10n.t("自动保存", "Auto save"), isPresented: Binding(
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
            Text(L10n.t("眼镜设置", "Glasses settings"))
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
                if showsIndicatorBrightness {
                    SettingsNavigationRow(
                        title: L10n.t("指示灯亮度", "Notification LED brightness"),
                        value: indicatorBrightnessSummary,
                        action: openIndicatorBrightnessOptions
                    )
                    .disabled(pairingCoordinator.astraA1BleManager.indicatorBrightness.isPending)
                    if showsCapability(\.wearingDetection) {
                        SettingsDivider()
                    }
                }
                if showsCapability(\.wearingDetection) {
                    SettingsToggleRow(
                        title: L10n.t("摘下休眠", "Sleep when removed"),
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
            SettingsSectionHeader(title: L10n.t("照片和视频", "Photos and videos"))

            SettingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsToggleRow(
                        title: L10n.t("选择图片水印样式", "Photo watermark style"),
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
                        title: L10n.t("短视频时间长度", "Video clip duration"),
                        value: pairingCoordinator.astraA1BleManager.isRecordDurationSettingPending
                            ? L10n.t("设置中…", "Setting…") : recordDurationTitle(recordDurationSeconds),
                        subtitle: L10n.t("设置视频录制时长，达到设定时间后自动停止", "Set recording duration; recording stops automatically at the limit"),
                        action: { showRecordDurationOptions = true }
                    )
                    .disabled(pairingCoordinator.astraA1BleManager.isRecordDurationSettingPending)
                    SettingsDivider()
                }
                if showsCapability(\.videoResolution) {
                    SettingsNavigationRow(
                        title: L10n.t("视频分辨率", "Video resolution"),
                        value: videoResolutionTitle,
                        action: { showVideoResolutionOptions = true }
                    )
                    SettingsDivider()
                }
                SettingsToggleRow(
                    title: L10n.t("自动保存", "Auto save"),
                    subtitle: L10n.t("照片和视频同步到 APP 后，自动保存到手机系统相册", "Automatically save photos and videos to your phone's album when synced to the app."),
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
        guard !ble.isVideoStarting, !ble.isVideoRecording, !ble.isVideoStopping, !ble.isTakingPhoto,
              !ble.isAIRecording, !ble.isAIVisionTransferBusy,
              !ble.isFirmwareUpgradeFlowBusy, ble.isDeviceRuntimeIdle else {
            DebugLogStore.logBLEEvent("settings queries deferred: device busy", detail: "target=\(ble.deviceBluetoothIdentifier ?? "none") runtime=\(ble.deviceRuntimeStatus.name) recording=\(ble.isVideoRecording)")
            return
        }
        if ble.deviceCapabilities.videoResolution { _ = ble.queryVideoResolution() }
        if ble.deviceCapabilities.wearingDetection { _ = ble.queryWearDetection() }
        if ble.deviceCapabilities.aiImageRecognition { _ = ble.syncAIVisionLevel(AiVisionSettings.level) }
        if ble.deviceCapabilities.voiceWakeupSetting {
            _ = ble.queryAIVoiceListeningDuration()
            refreshVoiceWakeUpState()
        }
        if ble.deviceCapabilities.recordDuration { _ = ble.queryRecordDuration() }
        if showsIndicatorBrightness { _ = ble.queryIndicatorBrightness() }
    }

    private func indicatorBrightnessTitle(_ level: IndicatorBrightnessLevel) -> String {
        switch level {
        case .low: return L10n.t("低", "Low")
        case .medium: return L10n.t("中", "Medium")
        case .high: return L10n.t("高", "High")
        }
    }

    private func indicatorBrightnessOptionTitle(_ level: IndicatorBrightnessLevel) -> String {
        let title = indicatorBrightnessTitle(level)
        guard pairingCoordinator.astraA1BleManager.indicatorBrightness.level == level else { return title }
        return title + L10n.t("（当前）", " (Current)")
    }

    private func openIndicatorBrightnessOptions() {
        guard isGlassesConnected, showsIndicatorBrightness else { return }
        let ble = pairingCoordinator.astraA1BleManager
        guard !ble.indicatorBrightness.isPending else { return }
        if ble.indicatorBrightness.level != nil {
            showIndicatorBrightnessOptions = true
            return
        }
        waitingForIndicatorBrightnessOptions = true
        if !ble.queryIndicatorBrightness() {
            waitingForIndicatorBrightnessOptions = false
            guideAlertMessage = L10n.t("暂时无法读取指示灯亮度，请稍后重试", "Unable to read indicator brightness. Please try again shortly.")
        }
    }

    private func applyIndicatorBrightness(_ level: IndicatorBrightnessLevel) {
        guard isGlassesConnected, showsIndicatorBrightness else { return }
        let ble = pairingCoordinator.astraA1BleManager
        guard !ble.indicatorBrightness.isPending else { return }
        guard ble.setIndicatorBrightness(level: level) else {
            guideAlertMessage = L10n.t("指示灯亮度同步失败，请重试", "Failed to sync indicator brightness. Please try again.")
            return
        }
    }

    private func handleIndicatorBrightnessResult(_ result: Gen2IndicatorBrightnessState.Result?) {
        guard isSettingsVisible, isGlassesConnected, let result else { return }
        let openOptions = waitingForIndicatorBrightnessOptions
        let userSet: Bool
        if case .set = result.request { userSet = true } else { userSet = false }
        guard openOptions || userSet else { return }
        waitingForIndicatorBrightnessOptions = false
        guard let failure = result.failure else {
            if openOptions { showIndicatorBrightnessOptions = true }
            return
        }
        switch failure {
        case .invalidParameter:
            guideAlertMessage = L10n.t("指示灯亮度参数错误，请重试", "Invalid indicator brightness level. Please try again.")
        case .storageFailed, .sendFailed, .rejected:
            guideAlertMessage = L10n.t("指示灯亮度同步失败，请重试", "Failed to sync indicator brightness. Please try again.")
        case .differentLevel:
            guideAlertMessage = L10n.t("设备未应用所选亮度，已显示当前档位，请重试", "The selected brightness was not applied. The current level is shown. Please try again.")
        case .timeout:
            guideAlertMessage = L10n.t("设备未响应，当前固件可能不支持指示灯亮度调节，请重试", "The glasses did not respond. This firmware may not support indicator brightness. Please try again.")
        }
    }

    private func recordDurationTitle(_ seconds: Int) -> String {
        if seconds < 60 {
            return L10n.t("\(seconds)秒", "\(seconds) sec")
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
        let ble = pairingCoordinator.astraA1BleManager
        guard !ble.isRecordDurationSettingPending else { return }
        guard ble.deviceRuntimeStatus == .standby || ble.deviceRuntimeStatus == .unknown else {
            guideAlertMessage = ble.deviceRuntimeStatus.busyMessage
            return
        }
        guard ble.setRecordTime(seconds: seconds) else {
            guideAlertMessage = L10n.t("录像时长设置失败", "Failed to set recording duration")
            return
        }
        // Gen1 persists and reports success only after the separate device query.
        guard ble.deviceGeneration != .gen1G5K61 else { return }
        recordDurationSeconds = seconds
        DeviceMediaSettings.setRecordDurationSeconds(seconds, userId: authSession.phoneNumber, deviceKey: mediaSettingsDeviceKey)
        guideAlertMessage = L10n.t("录像时长设置成功", "Recording duration set")
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
            guideAlertMessage = L10n.t("智能识别模式已保存", "AI vision mode saved")
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
                guideAlertMessage = L10n.t("语音唤醒设置失败", "Failed to update voice wake-up setting")
                scheduleVoiceWakeUpQuery(delay: 0.25)
            }
        } else if allowRetry {
            // Retry only when the transport did not enqueue the write.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                guard isCurrentVoiceWakeUpRequest(generation, peripheralID: peripheralID) else { return }
                sendVoiceWakeUpCommand(enabled, generation: generation, allowRetry: false)
            }
        } else if voiceWakeUpState.sendFailed(generation: generation) {
            guideAlertMessage = L10n.t("语音唤醒设置失败", "Failed to update voice wake-up setting")
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
                guideAlertMessage = L10n.t("语音唤醒设置失败", "Failed to update voice wake-up setting")
            }
        }
    }

    @ViewBuilder
    private var voiceWakeUpRow: some View {
        if voiceWakeUpState.phase == .ready || voiceWakeUpState.phase == .setting {
            SettingsToggleRow(
                title: L10n.t("语音唤醒", "Voice wake-up"),
                subtitle: L10n.t("开启后，可通过说出“嗨，眸刻”或“嘿，眸刻”唤醒语音助手", "When enabled, say \"Hi MOCO\" or \"Hey MOCO\" to wake up the voice assistant."),
                isOn: Binding(
                    get: { voiceWakeUpState.enabled ?? false },
                    set: { updateVoiceWakeUp($0) }
                )
            )
            .disabled(!voiceWakeUpState.canChange)
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("语音唤醒", "Voice wake-up"))
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
                    Text(L10n.t("未连接", "Not connected"))
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
            guideAlertMessage = L10n.t("连续对话时长设置失败", "Failed to update Listening duration")
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
            guideAlertMessage = L10n.t("连续对话时长设置成功", "Listening duration updated")
        case 2:
            guideAlertMessage = L10n.t("设备保存连续对话时长失败", "The glasses failed to save the Listening duration")
        default:
            guideAlertMessage = L10n.t("连续对话时长设置失败", "Failed to update Listening duration")
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
                    VoiceCommandsView()
                } label: {
                    SettingsNavigationLinkLabel(title: L10n.t("语音指令", "Voice commands"))
                }
                .buttonStyle(.plain)
                SettingsDivider()
                if showsCapability(\.voiceWakeupSetting) {
                    SettingsNavigationRow(
                        title: L10n.t("连续对话时长", "Listening duration"),
                        value: listeningDurationOptionTitle(listeningDurationSeconds),
                        subtitle: L10n.t(
                            "对话后 MOCO 将继续聆听一段时间，期间可直接说出下个指令，无需再次唤醒。",
                            "After speaking, the MOCO assistant will keep listening for a short period so you can give your next command without waking it up again."
                        ),
                        action: { showListeningDurationOptions = true }
                    )
                    .disabled(pendingListeningDurationSeconds != nil)
                    SettingsDivider()
                }
                if showsCapability(\.aiImageRecognition) {
                    SettingsNavigationRow(
                        title: L10n.t("智能图像识别模式", "AI vision mode"),
                        value: AiVisionSettings.levelTitle,
                        subtitle: L10n.t("平衡识别速度与图像清晰度", "Balance recognition speed and image clarity."),
                        action: { showAIVisionOptions = true }
                    )
                    SettingsDivider()
                }
                SettingsNavigationRow(
                    title: L10n.t("AI语音设置", "AI Voice Settings"),
                    value: L10n.t("眼镜系统语音", "Glasses System Voice"),
                    showsChevron: false,
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
                NavigationLink {
                    GlassesFirmwareUpgradeView(ble: pairingCoordinator.astraA1BleManager)
                } label: {
                    SettingsNavigationLinkLabel(
                        title: L10n.t("眼镜固件升级", "Glasses firmware upgrade"),
                        showsUpdateBadge: updateCoordinator.hasAnyUpdate
                    )
                }
                SettingsDivider()
                Button {
                    openNewbieGuide()
                } label: {
                    SettingsNavigationLinkLabel(title: L10n.t("新手引导", "Tutorial"))
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
                    SettingsNavigationLinkLabel(title: L10n.t("关于设备", "About device"))
                }
                if !isGen1SettingsDevice {
                    SettingsDivider()
                    SettingsNavigationRow(
                        title: L10n.t("恢复出厂设置", "Factory reset"),
                        action: { prepareFactoryReset() }
                    )
                }
            }
        }
    }

    private var unpairButton: some View {
        Button {
            checkDeviceConnectionBeforeUnpair()
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
        guard let serial = targetSerialNumber, boundDevice != nil else {
            unpairErrorMessage = L10n.t("设备未绑定", "Device not bound")
            return
        }
        guard !isUnpairing else { return }
        if pairingCoordinator.pendingUnpairRecovery(serialNumber: serial) != nil {
            showResumeUnpairConfirmation = true
            return
        }
        // An offline device cannot acknowledge a reset. Use the current
        // account's bound card and ask explicitly before server-only removal.
        // A separate userinfo refresh must not block reaching this decision.
        DebugLogStore.logConnect("unbind: settings preflight", detail: "target=\(serial) localTargetAvailable=\(isGlassesConnected) cloudConnectionIgnored=true freshBindingCheckAfterConfirmation=true next=\(isGlassesConnected ? "reset_then_unbind" : "confirm_forced_unbind")")
        if isGlassesConnected {
            showUnpairConfirmation = true
        } else {
            showForceUnpairConfirmation = true
        }
    }

    private func performUnpair(force: Bool) {
        guard !isUnpairing else { return }
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
        let recovery = pairingCoordinator.pendingUnpairRecovery(serialNumber: serialNumber)
        let sn = ([targetHardwareSN, cachedSN, liveTargetSN, recovery?.hardwareSN].compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.first) ?? ""

        guard force || recovery != nil || !sn.isEmpty else {
            unpairErrorMessage = L10n.t("未获取到设备 SN，请连接眼镜后重试", "Device SN unavailable. Connect glasses and try again")
            return
        }

        isUnpairing = true
        DebugLogStore.logConnect("unbind: settings confirmed", detail: "target=\(serialNumber) forced=\(force) hasHardwareSN=\(!sn.isEmpty) localTargetAvailable=\(isGlassesConnected)")
        Task {
            do {
                try await pairingCoordinator.unpairDevice(serialNumber: serialNumber, sn: sn, force: force)
                isUnpairing = false
                showUnpairSuccess = true
            } catch {
                isUnpairing = false
                DebugLogStore.logConnect("unbind: settings failed", detail: "target=\(serialNumber) forced=\(force) error=\(error.localizedDescription)")
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
    var showsChevron = true
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            SettingsNavigationLinkLabel(title: title, value: value, subtitle: subtitle, showsChevron: showsChevron)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsNavigationLinkLabel: View {
    let title: String
    var value: String?
    var subtitle: String?
    var showsUpdateBadge: Bool = false
    var showsChevron = true

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

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
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
