import SwiftUI
import UIKit

enum AlbumFilter: String, CaseIterable {
    case all = "全部"
    case photos = "图片"
    case videos = "视频"

    @MainActor
    var displayName: String {
        switch self {
        case .all: return L10n.t("全部", "All")
        case .photos: return L10n.t("图片", "Photos")
        case .videos: return L10n.t("视频", "Videos")
        }
    }
}

struct AlbumSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [StoredMediaItem]
}

struct AlbumView: View {
    @Binding var showsTabBar: Bool
    @EnvironmentObject private var pairingCoordinator: PairingCoordinator
    @EnvironmentObject private var importManager: MediaImportManager
    @EnvironmentObject private var authSession: AuthSession
    @ObservedObject private var mediaLibrary = MediaLibrary.shared

    @State private var selectedFilter: AlbumFilter = .all
    @State private var isSelectionMode = false
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var selectedDetailItem: StoredMediaItem?
    @State private var navigateToGlassesSettings = false
    @State private var settingsAlertMessage: String?
    @State private var importErrorMessage: String?
    @State private var importNoticeMessage: String?
    @State private var showImportPartialFailureDialog = false
    @State private var importPartialFailureMessage = ""
    @State private var showDeleteConfirmation = false
    @State private var sharePayload: SharePayload?
    @State private var isRefreshingDeviceFiles = false

    private var pendingImportCount: Int {
        pairingCoordinator.astraA1BleManager.pendingImportFileCount
    }

    private let albumColumnCount = 4
    private let albumGridSpacing: CGFloat = 1

    private var activeFilters: [AlbumFilter] {
        Array(AlbumFilter.allCases)
    }

    private var isAllVisibleSelected: Bool {
        !visibleItems.isEmpty && visibleItems.allSatisfy { selectedItemIDs.contains($0.id) }
    }

    private var filteredSections: [AlbumSection] {
        mediaLibrary.sections(filter: selectedFilter)
    }

    private var visibleItems: [StoredMediaItem] {
        filteredSections.flatMap(\.items)
    }

    private var albumGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: albumGridSpacing),
            count: albumColumnCount
        )
    }

    var body: some View {
        CompatibleNavigationStack {
            albumContent
                .mainTabRootContent(reservesTabBar: !isSelectionMode)
        }
    }

    private var albumContent: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if isSelectionMode {
                        selectionHeader
                    } else {
                        header
                        if pendingImportCount > 0 || importManager.pendingGen1RecoveryCount > 0 || importManager.isImporting {
                            importCard
                        }
                    }

                    if !mediaLibrary.items.isEmpty {
                        filterTabs
                    }

                    if filteredSections.isEmpty {
                        emptyAlbumView
                    } else {
                        ForEach(Array(filteredSections.enumerated()), id: \.element.id) { index, section in
                            sectionView(section, isFirst: index == 0)
                        }
                    }
                }
                .padding(.bottom, 24)
            }

            if isSelectionMode {
                selectionBottomBar
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: isSelectionMode)
        .animation(.easeInOut(duration: 0.2), value: pendingImportCount)
        .onAppear {
            importManager.refreshGen1Recovery(ble: pairingCoordinator.astraA1BleManager)
            if pairingCoordinator.astraA1BleManager.isDeviceAvailable {
                pairingCoordinator.astraA1BleManager.refreshPendingImportFiles()
            }
        }
        .onChangeCompat(of: navigateToGlassesSettings) { active in
            showsTabBar = !active && !isSelectionMode
        }
        .onChangeCompat(of: authSession.userInfo?.id) { _ in
            importManager.refreshGen1Recovery(ble: pairingCoordinator.astraA1BleManager)
        }
        .onChangeCompat(of: pairingCoordinator.astraA1BleManager.savedPeripheralUUIDString) { _ in
            importManager.refreshGen1Recovery(ble: pairingCoordinator.astraA1BleManager)
        }
        .fullScreenCover(item: $selectedDetailItem) { item in
            AlbumMediaDetailView(item: item)
        }
        .onChangeCompat(of: importManager.state) { newState in
            if case .completed(let imported, let failedPhotos, let failedVideos) = newState {
                if failedPhotos > 0 || failedVideos > 0 {
                    importPartialFailureMessage = importFailureMessage(
                        photos: failedPhotos,
                        videos: failedVideos
                    )
                    showImportPartialFailureDialog = true
                } else if imported == 0 {
                    importNoticeMessage = L10n.t("眼镜中暂无可导入的照片或视频", "No photos or videos to import from the glasses")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    importManager.resetStatus()
                }
            }
            if case .failed(let message) = newState {
                importErrorMessage = message
                importManager.resetStatus()
            }
        }
        .alert(L10n.t("导入失败", "Import Failed"), isPresented: $showImportPartialFailureDialog) {
            Button(L10n.t("复制错误日志", "Copy Error Log")) {
                UIPasteboard.general.string = importManager.lastFailureReport?.formattedLog ?? ""
            }
            Button(L10n.t("关闭", "Close"), role: .cancel) {
                importManager.clearFailureReport()
            }
        } message: {
            Text(importPartialFailureMessage)
        }
        .alert(L10n.t("导入失败", "Import Failed"), isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button(L10n.t("好的", "OK"), role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
        .alert(L10n.t("删除照片", "Delete Photos"), isPresented: $showDeleteConfirmation) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("删除", "Delete"), role: .destructive) {
                mediaLibrary.deleteItems(ids: selectedItemIDs)
                exitSelectionMode()
            }
        } message: {
            Text(L10n.t("此操作将删除 \(selectedItemIDs.count) 项，且无法恢复。", "This will permanently delete \(selectedItemIDs.count) item(s)."))
        }
        .sheet(item: $sharePayload) { payload in
            SystemShareSheet(urls: payload.urls) {
                sharePayload = nil
            }
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { importNoticeMessage != nil },
            set: { if !$0 { importNoticeMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(importNoticeMessage ?? "")
        }
        .background {
            NavigationLink(
                isActive: $navigateToGlassesSettings,
                destination: {
                    GlassesSettingsView(suppressesTabBarOnAppear: false)
                },
                label: { EmptyView() }
            )
            .hidden()
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { settingsAlertMessage != nil },
            set: { if !$0 { settingsAlertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(settingsAlertMessage ?? "")
        }
    }

    private func openGlassesSettings() {
        guard pairingCoordinator.astraA1BleManager.isDeviceAvailable else {
            settingsAlertMessage = L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
            return
        }
        navigateToGlassesSettings = true
    }

    private var emptyAlbumView: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 80)
            Image("android_album_empty")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 80)
            Text(L10n.t("暂无照片和视频", "No photos or videos"))
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
            if pendingImportCount > 0 {
                Text(L10n.t("可点击上方「导入」从眼镜导入", "Tap Import above to import from glasses"))
                    .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack {
            Text(L10n.t("相册", "Album"))
                .font(AppTheme.notoSansSC(size: HomeLayout.screenTitleSize, weight: .bold))
                .tracking(0)
                .foregroundStyle(AppTheme.primaryText)

            Spacer()

            HStack(spacing: 16) {
                if !mediaLibrary.items.isEmpty {
                    Button {
                        enterSelectionMode()
                    } label: {
                        Image("android_album_edit")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    }
                }

                Button {
                    openGlassesSettings()
                } label: {
                    Image("android_album_settings")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var selectionHeader: some View {
        ZStack {
            Text(L10n.t("已选择\(selectedItemIDs.count)项", "\(selectedItemIDs.count) Selected"))
                .font(AppTheme.notoSansSC(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Button {
                    if isAllVisibleSelected {
                        deselectAll()
                    } else {
                        selectAll()
                    }
                } label: {
                    Text(isAllVisibleSelected ? L10n.t("取消全选", "Deselect All") : L10n.t("全选", "Select All"))
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                }
                .disabled(visibleItems.isEmpty)

                Spacer()

                Button {
                    exitSelectionMode()
                } label: {
                    Text(L10n.t("完成", "Done"))
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var importCard: some View {
        if let request = importManager.manualWifiJoin {
            manualWifiJoinCard(request)
        } else if importManager.isImporting {
            importProgressCard
        } else {
            importPromptCard
        }
    }

    private func manualWifiJoinCard(_ request: ManualGlassesWifiJoin) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("请手动连接眼镜 Wi-Fi", "Connect to glasses Wi-Fi manually"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
            Text(L10n.t(
                "自动连接未成功，App 暂不关闭热点。请在手机「设置 → Wi-Fi」中连接下方热点；如提示无法访问互联网，请保持连接。返回后点击「已连接，重试」。找不到热点时可点击「重新开启热点」。请在 5 分钟内完成。",
                "Automatic connection failed. The app has not closed the hotspot. Join the network below in Settings → Wi-Fi and stay connected even without internet. Return and tap Connected, Retry. If the network is missing, tap Restart Hotspot. Complete within 5 minutes."
            ))
            if importManager.manualWifiHotspotMayBeOff {
                Text(L10n.t("眼镜已报告关机或热点收尾，热点可能已关闭，请重新开启热点。", "The glasses reported shutdown or cleanup. The hotspot may be off. Restart the hotspot."))
                    .foregroundStyle(.orange)
            }
            HStack {
                Text(L10n.t("热点：\(request.ssid)", "Network: \(request.ssid)"))
                Spacer(minLength: 8)
                Button(L10n.t("复制名称", "Copy Name")) {
                    UIPasteboard.general.string = request.ssid
                }
            }
            if !request.password.isEmpty {
                Text(L10n.t("密码：\(request.password)", "Password: \(request.password)"))
                Button(L10n.t("复制密码", "Copy Password")) {
                    UIPasteboard.general.string = request.password
                }
            }
            HStack(spacing: 18) {
                Button(L10n.t("已连接，重试", "Connected, Retry")) {
                    importManager.retryManualWifiJoin(id: request.id)
                }
                Button(L10n.t("取消导入", "Cancel Import")) {
                    importManager.cancelManualWifiJoin(id: request.id)
                }
            }
            Button(L10n.t("找不到网络？重新开启热点", "Network missing? Restart Hotspot")) {
                importManager.restartManualWifiHotspot(id: request.id)
            }
        }
        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
        .foregroundStyle(AppTheme.primaryText)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    private var importPromptCard: some View {
        HStack(spacing: 12) {
            Image("android_album_import")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)

            Text(importManager.pendingGen1RecoveryCount > 0
                 ? L10n.t("\(importManager.pendingGen1RecoveryCount)项原件可从手机恢复", "\(importManager.pendingGen1RecoveryCount) original(s) can be recovered from this phone")
                 : L10n.t("\(pendingImportCount)项照片和视频可导入手机", "\(pendingImportCount) photo(s)/video(s) ready to import"))
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

            VStack(spacing: 8) {
                Button {
                    startImport(recoverLocalFilesOnly: importManager.pendingGen1RecoveryCount > 0)
                } label: {
                    Text(importManager.pendingGen1RecoveryCount > 0 ? L10n.t("恢复", "Recover") : L10n.t("导入", "Import"))
                        .font(AppTheme.notoSansSC(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                .background(Color(red: 0.25, green: 0.25, blue: 0.25))
                .clipShape(Capsule())
                .disabled(!pairingCoordinator.astraA1BleManager.isDeviceAvailable && importManager.pendingGen1RecoveryCount == 0)
                .opacity(pairingCoordinator.astraA1BleManager.isDeviceAvailable || importManager.pendingGen1RecoveryCount > 0 ? 1 : 0.45)

                if importManager.pendingGen1RecoveryCount > 0,
                   pairingCoordinator.astraA1BleManager.isDeviceAvailable,
                   pairingCoordinator.astraA1BleManager.deviceGeneration == .gen1G5K61 {
                    Button {
                        startImport()
                    } label: {
                        Text(L10n.t("导入眼镜文件", "Import from glasses"))
                            .font(AppTheme.notoSansSC(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    private var importProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(importManager.statusText)
                    .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                Spacer(minLength: 0)
            }

            ProgressView(value: importManager.progress)
                .progressViewStyle(.linear)
                .tint(AppTheme.accent)
                .animation(.easeInOut(duration: 0.25), value: importManager.progress)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    private var filterTabs: some View {
        HStack(spacing: 20) {
            ForEach(activeFilters, id: \.self) { filter in
                Button {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        selectedFilter = filter
                        // 对齐安卓：切换图片/视频等 Tab 时清空选择，顶部计数归零。
                        if isSelectionMode {
                            selectedItemIDs.removeAll()
                        }
                    }
                } label: {
                    Text(filter.displayName)
                        // Android 三个 TextView 字重、padding 恒定，只切换背景与文字颜色。
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(selectedFilter == filter ? Color.white : AppTheme.secondaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(
                                    selectedFilter == filter
                                        ? Color(red: 0.25, green: 0.25, blue: 0.25)
                                        : Color.clear
                                )
                        )
                }
                .buttonStyle(.plain)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }

            Spacer(minLength: 0)

            Button {
                refreshDeviceFiles()
            } label: {
                Image("android_album_refresh")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .rotationEffect(.degrees(isRefreshingDeviceFiles ? 360 : 0))
                    .animation(
                        isRefreshingDeviceFiles
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: isRefreshingDeviceFiles
                    )
            }
            .buttonStyle(.plain)
            .disabled(isRefreshingDeviceFiles)
        }
        .padding(.horizontal, 20)
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                showDeleteConfirmation = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text(L10n.t("删除", "Delete"))
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                }
                .foregroundStyle(AppTheme.primaryText)
            }
            .buttonStyle(.plain)
            .disabled(selectedItemIDs.isEmpty)

            Spacer()

            Button {
                shareSelectedItems()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20))
                    Text(L10n.t("分享", "Share"))
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                }
                .foregroundStyle(AppTheme.primaryText)
            }
            .buttonStyle(.plain)
            .disabled(selectedItemIDs.isEmpty)
        }
        .padding(.horizontal, 40)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            AppTheme.cardBackground
                .shadow(color: AppTheme.cardShadow, radius: 8, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func sectionView(_ section: AlbumSection, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
                .padding(.horizontal, 16)
                .padding(.top, isFirst ? 4 : 28)
                .padding(.bottom, 10)

            LazyVGrid(columns: albumGridColumns, spacing: albumGridSpacing) {
                ForEach(section.items) { item in
                    mediaThumbnail(item)
                }
            }
        }
    }

    @ViewBuilder
    private func mediaThumbnail(_ item: StoredMediaItem) -> some View {
        let isSelected = selectedItemIDs.contains(item.id)
        let content = thumbnailContent(item: item, isSelected: isSelected)

        if isSelectionMode {
            Button {
                toggleSelection(for: item.id)
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            Button {
                selectedDetailItem = item
            } label: {
                content
            }
            .buttonStyle(.plain)
        }
    }

    private func thumbnailContent(item: StoredMediaItem, isSelected: Bool) -> some View {
        ZStack {
            thumbnailImage(for: item)
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipped()
                .background(Color(red: 0.92, green: 0.92, blue: 0.92))

            if item.isVideo, let duration = item.durationText {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(duration)
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }
            }

            if item.isFavorite && !isSelectionMode {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "heart.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.accent)
                            .padding(6)
                    }
                    Spacer()
                }
            }

            if isSelectionMode {
                ZStack {
                    if isSelected {
                        Color.black.opacity(0.25)
                    }
                    VStack {
                        HStack {
                            selectionIndicator(isSelected: isSelected)
                                .padding(8)
                            Spacer()
                        }
                        Spacer()
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func thumbnailImage(for item: StoredMediaItem) -> some View {
        let thumbURL = mediaLibrary.thumbnailURL(for: item)
        if let uiImage = UIImage(contentsOfFile: thumbURL.path) {
            Image(uiImage: uiImage)
                .resizable()
        } else if !item.isVideo,
                  let original = UIImage(contentsOfFile: mediaLibrary.originalURL(for: item).path) {
            Image(uiImage: original)
                .resizable()
        } else {
            Rectangle()
                .fill(Color(red: 0.90, green: 0.90, blue: 0.90))
                .overlay {
                    Image(systemName: item.isVideo ? "video" : "photo")
                        .foregroundStyle(AppTheme.secondaryText)
                }
        }
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isSelected ? AppTheme.accent : Color.white.opacity(0.85))
                .frame(width: 24, height: 24)

            Circle()
                .stroke(Color.white, lineWidth: isSelected ? 0 : 1.5)
                .frame(width: 24, height: 24)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func startImport(recoverLocalFilesOnly: Bool = false) {
        let ble = pairingCoordinator.astraA1BleManager
        importManager.refreshGen1Recovery(ble: ble)
        guard ble.isDeviceAvailable || importManager.pendingGen1RecoveryCount > 0 else {
            importErrorMessage = L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
            return
        }
        let boundDevice = authSession.userInfo?.device.first(where: {
            ble.matchesCurrentDevice(serialNumber: $0.serialNumber, hardwareSN: $0.hardwareSN)
        })
        let deviceKey = boundDevice?.serialNumber ?? ble.deviceBluetoothIdentifier ?? ble.deviceSN ?? ble.savedPeripheralUUIDString
        importManager.beginImport(
            ble: ble,
            library: mediaLibrary,
            expectedFileCount: pendingImportCount,
            autoSaveToPhotoLibrary: DeviceMediaSettings.isAutoSaveEnabled(
                userId: authSession.phoneNumber,
                deviceKey: deviceKey
            ),
            recoverLocalFilesOnly: recoverLocalFilesOnly
        )
    }

    private func refreshDeviceFiles() {
        let ble = pairingCoordinator.astraA1BleManager
        guard ble.isDeviceAvailable else {
            settingsAlertMessage = L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
            return
        }
        guard !isRefreshingDeviceFiles else { return }
        isRefreshingDeviceFiles = true
        ble.refreshPendingImportFiles()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            isRefreshingDeviceFiles = false
        }
    }

    private func importFailureMessage(photos: Int, videos: Int) -> String {
        switch (photos, videos) {
        case (0, 0):
            return ""
        case let (photoCount, 0):
            return L10n.t("有\(photoCount)张照片导入失败了", "\(photoCount) photo(s) failed to import")
        case let (0, videoCount):
            return L10n.t("有\(videoCount)个视频导入失败了", "\(videoCount) video(s) failed to import")
        case let (photoCount, videoCount):
            return L10n.t("有\(photoCount)张照片，\(videoCount)个视频导入失败了", "\(photoCount) photo(s) and \(videoCount) video(s) failed to import")
        }
    }

    private func enterSelectionMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSelectionMode = true
            showsTabBar = false
            selectedItemIDs.removeAll()
        }
    }

    private func exitSelectionMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSelectionMode = false
            showsTabBar = true
            selectedItemIDs.removeAll()
        }
    }

    private func deselectAll() {
        let visibleIDs = Set(visibleItems.map(\.id))
        selectedItemIDs.subtract(visibleIDs)
    }

    private func selectAll() {
        selectedItemIDs.formUnion(visibleItems.map(\.id))
    }

    private func toggleSelection(for id: UUID) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    private func shareSelectedItems() {
        let urls = mediaLibrary.items
            .filter { selectedItemIDs.contains($0.id) }
            .map { mediaLibrary.originalURL(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !urls.isEmpty else { return }
        sharePayload = SharePayload(urls: urls)
    }
}

#Preview {
    AlbumView(showsTabBar: .constant(true))
        .environmentObject(PairingCoordinator())
        .environmentObject(MediaImportManager.shared)
        .environmentObject(AuthSession())
}
