import AVFoundation
import Combine
import SwiftUI

enum RecordingTimeFormatter {
    static func elapsedTime(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func clockTime(seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

struct AIRecordingListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var pairingCoordinator: PairingCoordinator
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var recordingStore: AIRecordingStore
    @EnvironmentObject private var recordingImport: AIRecordingImportManager
    @EnvironmentObject private var mediaImport: MediaImportManager

    @State private var isRecordingUI = false
    @State private var recordingElapsed: TimeInterval = 0
    @State private var recordStartedAt: TimeInterval?
    @State private var selectedItemID: String?
    @State private var playbackProgress: [String: Double] = [:]
    @State private var playingItemID: String?
    @State private var isPlayerPlaying = false
    @State private var activeDialog: RecordingDialog?
    @State private var editingTitle = ""
    @State private var alertMessage: String?
    @State private var toastMessage: String?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playbackTimer: Timer?
    @State private var isSeeking = false
    @State private var isBatchMode = false
    @State private var batchSelectedIDs: Set<String> = []

    private var ble: AstraA1BleManager {
        pairingCoordinator.astraA1BleManager
    }

    private var recordings: [AIRecordingItem] {
        recordingStore.recordings
    }

    private var pendingImportCount: Int {
        guard ble.deviceGeneration != .gen1G5K61 else { return 0 }
        return max(ble.pendingRecordingImportFileCount, recordingImport.leftoverDeviceFileCount)
    }

    private var showImportCard: Bool {
        guard ble.deviceGeneration != .gen1G5K61 else { return false }
        if pendingImportCount > 0 { return true }
        if recordingImport.isImporting { return true }
        switch recordingImport.state {
        case .failed, .completed:
            return true
        default:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            GeometryReader { contentGeometry in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        if showImportCard {
                            importCard
                        }

                        if recordings.isEmpty {
                            emptyState
                                .frame(
                                    minHeight: max(
                                        0,
                                        contentGeometry.size.height - (showImportCard ? 92 : 0) - 32
                                    )
                                )
                        } else {
                            ForEach(recordings) { item in
                                if isBatchMode {
                                    batchRecordingRow(item)
                                } else if selectedItemID == item.id {
                                    expandedRecordingRow(item)
                                } else {
                                    collapsedRecordingRow(item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                }
            }

            if isBatchMode {
                batchDeleteBar
            } else {
                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 17)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .overlay {
            if let activeDialog {
                RecordingDialogOverlay(
                    dialog: activeDialog,
                    editingTitle: $editingTitle,
                    onCancel: { self.activeDialog = nil },
                    onConfirmEdit: confirmEdit,
                    onConfirmDelete: confirmDelete
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(AppTheme.notoSansSC(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.78))
                    .clipShape(Capsule())
                    .padding(.bottom, 100)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: activeDialog != nil)
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .onAppear {
            recordingStore.updateCurrentUser(authSession.phoneNumber)
            syncRecordingUIFromBLE()
            // 删除失败残留优先恢复；再查 hasnewfile（设备常只回媒体 type=0，录音残留靠本地记）。
            if ble.isDeviceAvailable {
                if ble.deviceGeneration != .gen1G5K61 {
                    recordingImport.restoreLeftoverPendingIfNeeded(ble: ble)
                }
                ble.refreshPendingImportFiles()
            }
        }
        .onDisappear {
            if ble.isAIRecording || isRecordingUI {
                _ = ble.stopAIRecord()
            }
            releasePlayer()
        }
        .onChangeCompat(of: ble.isAIRecording) { recording in
            if recording {
                if !isRecordingUI {
                    isRecordingUI = true
                    recordStartedAt = ProcessInfo.processInfo.systemUptime
                    recordingElapsed = 0
                }
            } else if isRecordingUI {
                isRecordingUI = false
                recordStartedAt = nil
                recordingElapsed = 0
            }
        }
        .onChangeCompat(of: ble.pendingRecordingImportFileCount) { count in
            if count > 0 {
                isRecordingUI = false
                recordStartedAt = nil
                recordingElapsed = 0
            }
        }
        .onChangeCompat(of: ble.mediaActionAlertMessage) { message in
            guard let message, !message.isEmpty else { return }
            alertMessage = message
            ble.mediaActionAlertMessage = nil
            if !ble.isAIRecording {
                isRecordingUI = false
                recordStartedAt = nil
                recordingElapsed = 0
            }
        }
        .onChangeCompat(of: recordingImport.state) { newState in
            switch newState {
            case .completed:
                recordingStore.reload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    recordingImport.resetStatus()
                }
            case .failed(let message):
                alertMessage = message
            default:
                break
            }
        }
        .onChangeCompat(of: recordings.map(\.id)) { ids in
            batchSelectedIDs.formIntersection(ids)
            if ids.isEmpty, isBatchMode {
                exitBatchMode()
            }
        }
        .task(id: isRecordingUI) {
            guard isRecordingUI else { return }
            // A body-created Timer publisher restarts when BLE changes redraw this
            // page. This task keeps its identity until recording or visibility changes.
            while !Task.isCancelled {
                guard let started = recordStartedAt else { return }
                let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
                if Int(elapsed) != Int(recordingElapsed) {
                    recordingElapsed = elapsed
                }
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func syncRecordingUIFromBLE() {
        if ble.isAIRecording {
            isRecordingUI = true
            if recordStartedAt == nil {
                recordStartedAt = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    private func openEditDialog(for item: AIRecordingItem) {
        editingTitle = item.title
        activeDialog = .edit(item.id)
    }

    private func openDeleteDialog(for item: AIRecordingItem) {
        activeDialog = .delete(item.id)
    }

    private func confirmEdit() {
        guard case .edit(let itemID) = activeDialog else { return }
        recordingStore.updateTitle(id: itemID, title: editingTitle)
        activeDialog = nil
    }

    private func confirmDelete() {
        switch activeDialog {
        case .delete(let itemID):
            if playingItemID == itemID {
                releasePlayer()
            }
            recordingStore.deleteRecording(id: itemID)
            playbackProgress.removeValue(forKey: itemID)
            if selectedItemID == itemID {
                selectedItemID = nil
            }
        case .batchDelete:
            let deletingIDs = batchSelectedIDs
            if let playingItemID, deletingIDs.contains(playingItemID) {
                releasePlayer()
            }
            recordingStore.deleteRecordings(ids: deletingIDs)
            deletingIDs.forEach { playbackProgress.removeValue(forKey: $0) }
            exitBatchMode()
        default:
            return
        }
        activeDialog = nil
    }

    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    private var navigationBar: some View {
        Group {
            if isBatchMode {
                HStack {
                    Button(allRecordingsSelected ? L10n.t("取消全选", "Deselect all") : L10n.t("全选", "Select all")) {
                        toggleSelectAll()
                    }
                    .frame(minWidth: 64, alignment: .leading)

                    Spacer()

                    Text(L10n.t("已选择 \(batchSelectedIDs.count) 项", "\(batchSelectedIDs.count) selected"))
                        .font(AppTheme.notoSansSC(size: 15, weight: .bold))

                    Spacer()

                    Button(L10n.t("完成", "Done")) {
                        exitBatchMode()
                    }
                    .frame(minWidth: 64, alignment: .trailing)
                }
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .frame(height: 44)
            } else {
                ZStack {
                    Text(L10n.t("AI录音", "AI Recording"))
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
                        .buttonStyle(.plain)

                        Spacer()

                        if !recordings.isEmpty {
                            Button {
                                enterBatchMode()
                            } label: {
                                Image("android_album_edit")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24, height: 24)
                                    .frame(width: 44, height: 44, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var allRecordingsSelected: Bool {
        !recordings.isEmpty && batchSelectedIDs.count == recordings.count
    }

    private func enterBatchMode() {
        releasePlayer()
        selectedItemID = nil
        batchSelectedIDs.removeAll()
        isBatchMode = true
    }

    private func exitBatchMode() {
        isBatchMode = false
        batchSelectedIDs.removeAll()
    }

    private func toggleBatchSelection(_ itemID: String) {
        if batchSelectedIDs.contains(itemID) {
            batchSelectedIDs.remove(itemID)
        } else {
            batchSelectedIDs.insert(itemID)
        }
    }

    private func toggleSelectAll() {
        if allRecordingsSelected {
            batchSelectedIDs.removeAll()
        } else {
            batchSelectedIDs = Set(recordings.map(\.id))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image("android_ai_record_empty")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 80)

            Text(L10n.t(
                "暂无音频文件\n双指单击触控板，开始录音",
                "No audio files\nDouble-tap the touchpad with two fingers to start recording"
            ))
                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image("android_ai_record_import")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)

                Text(importCardText)
                    .font(AppTheme.notoSansSC(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button {
                    startImport()
                } label: {
                    Text(importButtonTitle)
                        .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color(red: 0.25, green: 0.25, blue: 0.25))
                        .clipShape(Capsule())
                }
                .disabled(recordingImport.isImporting || !ble.isDeviceAvailable)
                .opacity(ble.isDeviceAvailable ? 1 : 0.45)
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var importCardText: String {
        if recordingImport.isImporting {
            return recordingImport.statusText
        }
        if case .failed(let message) = recordingImport.state {
            return message
        }
        if case .completed(let imported, _) = recordingImport.state {
            return L10n.t("已导入 \(imported) 项", "Imported \(imported) item(s)")
        }
        return L10n.t("\(pendingImportCount)个录音文件待导入", "\(pendingImportCount) recordings pending import")
    }

    private var importButtonTitle: String {
        if case .failed = recordingImport.state {
            return L10n.t("重试", "Retry")
        }
        return L10n.t("导入", "Import")
    }

    private func startImport() {
        guard ble.isDeviceAvailable else {
            alertMessage = L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
            return
        }
        recordingImport.resetStatus()
        recordingImport.beginImport(
            ble: ble,
            store: recordingStore,
            expectedFileCount: pendingImportCount
        )
    }

    private func collapsedRecordingRow(_ item: AIRecordingItem) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedItemID = item.id
                if playbackProgress[item.id] == nil {
                    playbackProgress[item.id] = 0
                }
            }
        } label: {
            collapsedRecordingCard(item)
        }
        .buttonStyle(.plain)
    }

    private func batchRecordingRow(_ item: AIRecordingItem) -> some View {
        Button {
            toggleBatchSelection(item.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: batchSelectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(
                        batchSelectedIDs.contains(item.id)
                            ? Color(red: 1.00, green: 0.12, blue: 0.29)
                            : Color(red: 0.70, green: 0.70, blue: 0.70)
                    )
                    .frame(width: 28, height: 28)

                collapsedRecordingCard(item)
            }
        }
        .buttonStyle(.plain)
    }

    private func collapsedRecordingCard(_ item: AIRecordingItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "play.circle")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)

            recordingHeaderText(item)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func recordingHeaderText(_ item: AIRecordingItem) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("文件名： \(item.title)", "File: \(item.title)"))
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)

                Text(item.durationText)
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
            }

            Spacer(minLength: 8)

            Text(item.timeText)
                .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
        }
    }

    private func expandedRecordingRow(_ item: AIRecordingItem) -> some View {
        let progress = playbackProgress[item.id, default: 0]
        let totalSeconds = max(item.totalSeconds, 1)
        let currentSeconds = Int(Double(totalSeconds) * progress)
        let isPlaying = playingItemID == item.id && isPlayerPlaying

        return VStack(spacing: 16) {
            HStack(spacing: 14) {
                Button {
                    togglePlayback(item)
                } label: {
                    Image(systemName: isPlaying ? "pause.circle" : "play.circle")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                }
                .buttonStyle(.plain)

                recordingHeaderText(item)
            }

            VStack(spacing: 8) {
                RecordingProgressSlider(
                    value: Binding(
                        get: { playbackProgress[item.id, default: 0] },
                        set: { newValue in
                            playbackProgress[item.id] = newValue
                            seekPlayback(item: item, progress: newValue)
                        }
                    ),
                    onEditingChanged: { editing in
                        isSeeking = editing
                    }
                )

                HStack {
                    Text(RecordingTimeFormatter.clockTime(seconds: currentSeconds))
                        .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)

                    Spacer()

                    Text(RecordingTimeFormatter.clockTime(seconds: item.totalSeconds))
                        .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

            HStack {
                Button {
                    openEditDialog(for: item)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 20))
                        .foregroundStyle(AppTheme.primaryText)
                }
                .buttonStyle(.plain)

                Button {
                    openDeleteDialog(for: item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                        .foregroundStyle(AppTheme.primaryText)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)

                Spacer()

                Button {
                    showToast(L10n.t("AI功能暂未开放", "AI is not available yet"))
                } label: {
                    Text("AI")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AppTheme.primaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var bottomBar: some View {
        if isRecordingUI {
            recordingStatusBar
        } else {
            startRecordingButton
        }
    }

    private var startRecordingButton: some View {
        Button {
            startRecording()
        } label: {
            Text(L10n.t("开始录音", "Start recording"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 265, height: 48)
                .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                .clipShape(Capsule())
        }
        .disabled(recordingImport.isImporting || !ble.isDeviceAvailable)
        .opacity(ble.isDeviceAvailable ? 1 : 0.45)
    }

    private var recordingStatusBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(RecordingTimeFormatter.elapsedTime(seconds: recordingElapsed))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .monospacedDigit()

                Text(L10n.t("正在录音中...", "Recording..."))
                    .font(AppTheme.notoSansSC(size: 10, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 12)

            Button {
                stopRecording()
            } label: {
                Text(L10n.t("结束录音", "End recording"))
                    .font(AppTheme.notoSansSC(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 48)
                    .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var batchDeleteBar: some View {
        Button {
            guard !batchSelectedIDs.isEmpty else {
                showToast(L10n.t("请先选择要操作的内容", "Select an item first"))
                return
            }
            activeDialog = .batchDelete(batchSelectedIDs.count)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .regular))
                Text(L10n.t("删除", "Delete"))
                    .font(AppTheme.notoSansSC(size: 12, weight: .regular))
            }
            .foregroundStyle(AppTheme.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(batchSelectedIDs.isEmpty)
        .opacity(batchSelectedIDs.isEmpty ? 0.45 : 1)
        .background(AppTheme.cardBackground.ignoresSafeArea(edges: .bottom))
    }

    private func startRecording() {
        guard ble.isDeviceAvailable else {
            alertMessage = L10n.t("当前没有可用设备，请先连接已绑定的眼镜", "No available device. Connect your bound glasses first")
            return
        }
        guard !recordingImport.isImporting else {
            alertMessage = L10n.t("正在导入录音，请稍后再试", "Importing recordings, try again later")
            return
        }
        guard !mediaImport.isImporting else {
            alertMessage = L10n.t("相册正在导入，请稍后再试", "Gallery import in progress, try again later")
            return
        }
        // UI 由 ble.isAIRecording（对时后约 180ms）驱动。
        _ = ble.startAIRecord()
    }

    private func stopRecording() {
        _ = ble.stopAIRecord()
        isRecordingUI = false
        recordStartedAt = nil
        recordingElapsed = 0
    }

    // MARK: - Playback

    private func togglePlayback(_ item: AIRecordingItem) {
        if playingItemID == item.id {
            if isPlayerPlaying {
                pausePlayback()
            } else {
                resumePlayback()
            }
            return
        }
        play(item)
    }

    private func play(_ item: AIRecordingItem) {
        guard item.playable else {
            showToast(L10n.t("该录音暂不可播放", "This recording cannot be played"))
            return
        }
        let url = URL(fileURLWithPath: item.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast(L10n.t("录音文件不存在", "Recording file is missing"))
            return
        }

        releasePlayer()
        do {
            try GlassesAudioRouteController.activate(.playback)
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            playingItemID = item.id
            isPlayerPlaying = true
            selectedItemID = item.id
            playbackProgress[item.id] = 0
            startPlaybackTimer()
        } catch {
            showToast(error.localizedDescription)
            releasePlayer()
        }
    }

    private func pausePlayback() {
        audioPlayer?.pause()
        isPlayerPlaying = false
        stopPlaybackTimer()
        updateProgressFromPlayer()
    }

    private func resumePlayback() {
        audioPlayer?.play()
        isPlayerPlaying = true
        startPlaybackTimer()
    }

    private func seekPlayback(item: AIRecordingItem, progress: Double) {
        guard playingItemID == item.id, let player = audioPlayer else { return }
        let duration = player.duration
        guard duration > 0 else { return }
        player.currentTime = duration * min(max(progress, 0), 1)
        updateProgressFromPlayer()
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                updateProgressFromPlayer()
            }
        }
        if let playbackTimer {
            RunLoop.main.add(playbackTimer, forMode: .common)
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func updateProgressFromPlayer() {
        guard let player = audioPlayer, let id = playingItemID else { return }
        if !player.isPlaying, isPlayerPlaying, player.currentTime >= player.duration - 0.05 {
            playbackProgress[id] = 0
            isPlayerPlaying = false
            releasePlayer()
            return
        }
        guard !isSeeking else { return }
        let duration = max(player.duration, 0.001)
        playbackProgress[id] = min(max(player.currentTime / duration, 0), 1)
        isPlayerPlaying = player.isPlaying
    }

    private func releasePlayer() {
        stopPlaybackTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        playingItemID = nil
        isPlayerPlaying = false
    }
}

private enum RecordingDialog: Equatable {
    case edit(String)
    case delete(String)
    case batchDelete(Int)
}

private struct RecordingDialogOverlay: View {
    let dialog: RecordingDialog
    @Binding var editingTitle: String
    let onCancel: () -> Void
    let onConfirmEdit: () -> Void
    let onConfirmDelete: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            switch dialog {
            case .edit:
                editDialog
            case .delete:
                deleteDialog
            case .batchDelete(let count):
                deleteDialog(count: count)
            }
        }
        .transition(.opacity)
    }

    private var editDialog: some View {
        VStack(spacing: 20) {
            Text(L10n.t("编辑标题", "Edit title"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.primaryText)

            TextField("", text: $editingTitle)
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color(red: 0.88, green: 0.88, blue: 0.88), lineWidth: 1)
                )

            dialogButtons(
                confirmTitle: L10n.t("确定", "OK"),
                onConfirm: onConfirmEdit
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var deleteDialog: some View {
        deleteDialog(count: nil)
    }

    private func deleteDialog(count: Int?) -> some View {
        VStack(spacing: 28) {
            Text(deleteConfirmationText(count: count))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            dialogButtons(
                confirmTitle: L10n.t("删除", "Delete"),
                onConfirm: onConfirmDelete
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func deleteConfirmationText(count: Int?) -> String {
        guard let count else {
            return L10n.t("确认删除吗？", "Delete this recording?")
        }
        return L10n.t("是否删除\(count)个文件?", "Delete \(count) files?")
    }

    private func dialogButtons(confirmTitle: String, onConfirm: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Text(L10n.t("取消", "Cancel"))
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(red: 0.92, green: 0.92, blue: 0.92))
                    .clipShape(Capsule())
            }

            Button(action: onConfirm) {
                Text(confirmTitle)
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                    .clipShape(Capsule())
            }
        }
    }
}

private struct RecordingProgressSlider: View {
    @Binding var value: Double
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            let thumbSize: CGFloat = 14
            let trackHeight: CGFloat = 4
            let fillWidth = max(thumbSize / 2, CGFloat(value) * geometry.size.width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(red: 0.90, green: 0.90, blue: 0.90))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color.black)
                    .frame(width: fillWidth, height: trackHeight)

                Circle()
                    .fill(Color.white)
                    .overlay {
                        Circle()
                            .stroke(Color.black.opacity(0.15), lineWidth: 1)
                    }
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: fillWidth - thumbSize / 2)
            }
            .frame(height: thumbSize)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onEditingChanged(true)
                        let newValue = gesture.location.x / geometry.size.width
                        value = min(max(newValue, 0), 1)
                    }
                    .onEnded { _ in
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 14)
    }
}

private struct AIRecordingEmptyFolderIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                AIRecordingFolderBackShape()
                    .fill(Color(red: 0.62, green: 0.62, blue: 0.62))

                AIRecordingFolderFrontShape()
                    .fill(Color(red: 0.62, green: 0.62, blue: 0.62))

                HStack(alignment: .center, spacing: width * 0.045) {
                    waveformBar(width: width * 0.015, height: height * 0.22)
                    waveformBar(width: width * 0.015, height: height * 0.38)
                    waveformBar(width: width * 0.015, height: height * 0.54)
                    waveformBar(width: width * 0.015, height: height * 0.36)
                    waveformBar(width: width * 0.015, height: height * 0.22)
                }
                .frame(width: width * 0.43, height: height * 0.55)
                .offset(x: width * 0.12, y: height * 0.18)
            }
        }
    }

    private func waveformBar(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color.black)
            .frame(width: width, height: height)
    }
}

private struct AIRecordingFolderBackShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.88))
        path.addLine(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.18))
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.20, y: rect.height * 0.09),
            control: CGPoint(x: rect.width * 0.10, y: rect.height * 0.09)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.46, y: rect.height * 0.09))
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.54, y: rect.height * 0.23),
            control: CGPoint(x: rect.width * 0.54, y: rect.height * 0.09)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.82, y: rect.height * 0.23))
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.31),
            control: CGPoint(x: rect.width * 0.90, y: rect.height * 0.23)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.75))
        path.closeSubpath()
        return path
    }
}

private struct AIRecordingFolderFrontShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.88))
        path.addLine(to: CGPoint(x: rect.width * 0.22, y: rect.height * 0.37))
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.31, y: rect.height * 0.30),
            control: CGPoint(x: rect.width * 0.24, y: rect.height * 0.30)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.91, y: rect.height * 0.30))
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.98, y: rect.height * 0.42),
            control: CGPoint(x: rect.width * 0.99, y: rect.height * 0.31)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.83, y: rect.height * 0.88))
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.73, y: rect.height * 0.96),
            control: CGPoint(x: rect.width * 0.81, y: rect.height * 0.96)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.96))
        path.closeSubpath()
        return path
    }
}

#Preview {
    CompatibleNavigationStack {
        AIRecordingListView()
            .environmentObject(PairingCoordinator())
            .environmentObject(AuthSession())
            .environmentObject(AIRecordingStore.shared)
            .environmentObject(AIRecordingImportManager.shared)
            .environmentObject(MediaImportManager.shared)
    }
}
