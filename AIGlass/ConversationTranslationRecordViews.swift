import SwiftUI

/// 对话翻译记录列表：对齐安卓 `ConversationTranslationRecordListActivity`。
struct ConversationTranslationRecordListView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var records: [ConversationTranslationRecord] = []
    @State private var selectionMode = false
    @State private var selectedIds: Set<UUID> = []
    @State private var showsDeleteConfirm = false
    @State private var selectedRecord: ConversationTranslationRecord?

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
                    LazyVStack(spacing: 12) {
                        ForEach(records) { record in
                            recordRow(record)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, selectionMode ? 90 : 24)
                }
            }

            if selectionMode {
                actionBar
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .onAppear { reload() }
        .compatibleNavigationDestination(item: $selectedRecord) { record in
            ConversationTranslationRecordDetailView(record: record)
        }
        .alert(L10n.t("删除确认", "Confirm Delete"), isPresented: $showsDeleteConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("确定", "OK"), role: .destructive) {
                ConversationTranslationRecordStore.delete(ids: selectedIds)
                exitSelectionMode()
                reload()
            }
        } message: {
            Text(L10n.t("确定要删除选中 \(selectedIds.count) 条记录吗？此操作不可恢复", "Delete \(selectedIds.count) selected record(s)? This cannot be undone."))
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(selectionMode ? L10n.t("已选择\(selectedIds.count)项", "\(selectedIds.count) Selected") : L10n.t("对话翻译记录", "Conversation Records"))
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

                if selectionMode {
                    Button(L10n.t("完成", "Done")) { exitSelectionMode() }
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                } else if !records.isEmpty {
                    Button {
                        enterSelectionMode()
                    } label: {
                        Image("android_album_edit")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var actionBar: some View {
        HStack {
            Button {
                if selectedIds.count == records.count {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(records.map(\.id))
                }
            } label: {
                Text(selectedIds.count == records.count ? L10n.t("取消全选", "Deselect All") : L10n.t("全选", "Select All"))
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                guard !selectedIds.isEmpty else { return }
                showsDeleteConfirm = true
            } label: {
                Text(L10n.t("删除", "Delete"))
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(selectedIds.isEmpty ? AppTheme.secondaryText : Color.red)
            }
            .buttonStyle(.plain)
            .disabled(selectedIds.isEmpty)
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
        .background(AppTheme.cardBackground)
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
                        .font(.system(size: 20))
                        .foregroundStyle(selectedIds.contains(record.id) ? AppTheme.accent : Color(red: 0.78, green: 0.78, blue: 0.78))
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(selectionMode
                             ? "\(TranslationLanguage.fromDisplayName(record.glassesLanguage).displayName) ⇄ \(TranslationLanguage.fromDisplayName(record.phoneLanguage).displayName)"
                             : title(for: record))
                            .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(selectionMode ? nil : 1)
                        Spacer()
                    }
                    Text(selectionMode ? previewText(for: record) : listPreviewText(for: record))
                        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(selectionMode ? 2 : 1)
                    Text(selectionMode ? Self.dateFormatter.string(from: record.updatedAt) : metaText(for: record))
                        .font(selectionMode ? .system(size: 11) : AppTheme.notoSansSC(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .padding(16)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func title(for record: ConversationTranslationRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return L10n.t("对话翻译记录", "Conversation Record ") + formatter.string(from: record.updatedAt)
    }

    private func listPreviewText(for record: ConversationTranslationRecord) -> String {
        if let first = record.messages.first {
            let text = first.sourceText.isEmpty ? first.translatedText : first.sourceText
            if !text.isEmpty { return text.replacingOccurrences(of: "\n", with: " ") }
        }
        return L10n.t("\(record.messages.count) 条对话", "\(record.messages.count) messages")
    }

    private func metaText(for record: ConversationTranslationRecord) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        let languages = "\(TranslationLanguage.fromDisplayName(record.glassesLanguage).displayName)-\(TranslationLanguage.fromDisplayName(record.phoneLanguage).displayName)"
        return L10n.t("语言：", "Languages: ") + languages + "  " + formatter.string(from: record.updatedAt)
    }

    private func previewText(for record: ConversationTranslationRecord) -> String {
        if let last = record.messages.last {
            if !last.translatedText.isEmpty { return last.translatedText }
            if !last.sourceText.isEmpty { return last.sourceText }
        }
        return L10n.t("\(record.messages.count) 条对话", "\(record.messages.count) messages")
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
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
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
