import SwiftUI

/// 对话翻译记录列表：对齐安卓 `ConversationTranslationRecordListActivity`。
struct ConversationTranslationRecordListView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var records: [ConversationTranslationRecord] = []
    @State private var selectionMode = false
    @State private var selectedIds: Set<UUID> = []
    @State private var showsDeleteConfirm = false
    @State private var selectedRecord: ConversationTranslationRecord?
    @State private var sharePayload: SharePayload?
    @State private var exportDirectory: URL?
    @State private var alertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            if records.isEmpty {
                Spacer()
                Text(L10n.t("暂无对话翻译记录", "No conversation translation records"))
                    .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(records) { record in
                            recordRow(record)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }

            if selectionMode {
                TranslationRecordSelectionBar(
                    hasSelection: !selectedIds.isEmpty,
                    onDelete: { showsDeleteConfirm = true },
                    onShare: shareSelection
                )
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .onAppear { reload() }
        .compatibleNavigationDestination(item: $selectedRecord) { record in
            ConversationTranslationRecordDetailView(record: record)
        }
        .overlay {
            if showsDeleteConfirm {
                TranslationRecordDeleteConfirmation(
                    count: selectedIds.count,
                    onCancel: { showsDeleteConfirm = false },
                    onDelete: {
                        ConversationTranslationRecordStore.delete(ids: selectedIds)
                        showsDeleteConfirm = false
                        exitSelectionMode()
                        reload()
                    }
                )
            }
        }
        .sheet(item: $sharePayload, onDismiss: removeExport) { payload in
            SystemShareSheet(urls: payload.urls)
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(selectionMode ? L10n.t("已选择\(selectedIds.count)项", "\(selectedIds.count) Selected") : L10n.t("对话翻译记录", "Conversation Records"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, selectionMode ? 100 : 52)

            HStack {
                Group {
                    if selectionMode {
                        Button(allRecordsSelected ? L10n.t("取消全选", "Deselect All") : L10n.t("全选", "Select All")) {
                            selectedIds = allRecordsSelected ? [] : Set(records.map(\.id))
                        }
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                    } else {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(AppTheme.primaryText)
                                .frame(width: 44, height: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: selectionMode ? 92 : 44, alignment: .leading)

                Spacer(minLength: 0)

                Group {
                    if selectionMode {
                        Button(L10n.t("完成", "Done")) { exitSelectionMode() }
                            .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                            .foregroundStyle(AppTheme.primaryText)
                            .frame(minHeight: 44)
                    } else if !records.isEmpty {
                        Button {
                            enterSelectionMode()
                        } label: {
                            Image("android_album_edit")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 28)
                                .frame(width: 44, height: 44, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.t("选择记录", "Select Records"))
                    }
                }
                .frame(width: selectionMode ? 92 : 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var allRecordsSelected: Bool {
        !records.isEmpty && selectedIds.count == records.count
    }

    private func recordRow(_ record: ConversationTranslationRecord) -> some View {
        Button {
            if selectionMode {
                toggleSelection(record.id)
            } else {
                selectedRecord = record
            }
        } label: {
            HStack(spacing: 12) {
                if selectionMode {
                    Image(systemName: selectedIds.contains(record.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(selectedIds.contains(record.id) ? AppTheme.accent : Color(red: 0.78, green: 0.78, blue: 0.78))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(title(for: record))
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                    Text(previewText(for: record))
                        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                    Text(metaText(for: record))
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(AppTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .buttonStyle(.plain)
    }

    private func title(for record: ConversationTranslationRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return L10n.t("对话翻译记录", "Conversation Record ") + formatter.string(from: record.updatedAt)
    }

    private func previewText(for record: ConversationTranslationRecord) -> String {
        if let first = record.messages.first {
            let text = first.sourceText.isEmpty ? first.translatedText : first.sourceText
            if !text.isEmpty { return text.replacingOccurrences(of: "\n", with: " ") }
        }
        return L10n.t("\(record.messages.count) 条对话", "\(record.messages.count) messages")
    }

    private func metaText(for record: ConversationTranslationRecord) -> String {
        let languages = "\(TranslationLanguage.fromDisplayName(record.glassesLanguage).displayName)-\(TranslationLanguage.fromDisplayName(record.phoneLanguage).displayName)"
        return L10n.t("语言：", "Languages: ") + languages + "  " + Self.dateFormatter.string(from: record.updatedAt)
    }

    private func shareSelection() {
        let selected = records.filter { selectedIds.contains($0.id) }
        guard !selected.isEmpty else { return }
        let text = selected.map { record in
            let messages = record.messages.map { "\($0.sourceText)\n\($0.translatedText)" }.joined(separator: "\n\n")
            return "\(title(for: record))\n\(metaText(for: record))\n\n\(messages)"
        }.joined(separator: "\n\n--------------------------------\n\n")
        do {
            let payload = try TranslationRecordTextExport.makePayload(text: text)
            exportDirectory = payload.urls.first?.deletingLastPathComponent()
            sharePayload = payload
        } catch {
            alertMessage = L10n.t("记录导出失败，请重试", "Could not export the records. Please try again.")
        }
    }

    private func removeExport() {
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
    }

    private func reload() {
        records = ConversationTranslationRecordStore.getAll()
    }

    private func enterSelectionMode() {
        selectionMode = true
        selectedIds.removeAll()
    }

    private func exitSelectionMode() {
        selectionMode = false
        selectedIds.removeAll()
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()
}

/// Both translation histories use the same selection actions and confirmation style.
struct TranslationRecordSelectionBar: View {
    let hasSelection: Bool
    let onDelete: () -> Void
    let onShare: () -> Void

    var body: some View {
        HStack {
            action(title: L10n.t("删除", "Delete"), icon: "trash.fill", action: onDelete)
            Spacer()
            action(title: L10n.t("分享", "Share"), icon: "square.and.arrow.up", action: onShare)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
        .background(AppTheme.cardBackground)
    }

    private func action(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .medium))
                Text(title)
                    .font(AppTheme.notoSansSC(size: 13, weight: .regular))
            }
            .foregroundStyle(hasSelection ? AppTheme.primaryText : AppTheme.secondaryText)
            .frame(minWidth: 64, minHeight: 48)
        }
        .buttonStyle(.plain)
        .disabled(!hasSelection)
    }
}

struct TranslationRecordDeleteConfirmation: View {
    let count: Int
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 32) {
                Text(L10n.t("是否删除\(count)个文件？", "Delete \(count) file(s)?"))
                    .font(AppTheme.notoSansSC(size: 17, weight: .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)

                HStack(spacing: 24) {
                    Button(L10n.t("取消", "Cancel"), action: onCancel)
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color(red: 0.82, green: 0.82, blue: 0.82))
                        .clipShape(Capsule())
                    Button(L10n.t("删除", "Delete"), action: onDelete)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                        .clipShape(Capsule())
                }
                .font(AppTheme.notoSansSC(size: 17, weight: .regular))
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .transition(.opacity)
    }
}

/// Export only the records selected by the user; the presenting page removes the file on dismissal.
enum TranslationRecordTextExport {
    static func makePayload(text: String) throws -> SharePayload {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIGlassTranslationExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("translation-records.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return SharePayload(urls: [url])
    }
}

/// 对话翻译记录详情。
struct ConversationTranslationRecordDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let record: ConversationTranslationRecord

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(record.messages) { message in
                        HStack {
                            if message.side == "phone" { Spacer(minLength: 54) }
                            VStack(alignment: .leading, spacing: 5) {
                                if !message.sourceText.isEmpty {
                                    Text(message.sourceText)
                                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                if !message.translatedText.isEmpty {
                                    Text(message.translatedText)
                                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                                        .foregroundStyle(AppTheme.primaryText)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(message.side == "glasses"
                                ? Color(red: 0.86, green: 0.92, blue: 1)
                                : Color(red: 0.92, green: 0.87, blue: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            if message.side == "glasses" { Spacer(minLength: 54) }
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("记录详情", "Record Detail"))
                .font(AppTheme.notoSansSC(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
