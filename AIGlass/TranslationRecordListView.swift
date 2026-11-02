import SwiftUI

/// 同声传译记录列表：对齐安卓 `TranslationRecordListActivity`。
struct TranslationRecordListView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var records: [SimultaneousTranslationRecord] = []
    @State private var selectionMode = false
    @State private var selectedIds: Set<String> = []
    @State private var showsDeleteConfirm = false
    @State private var alertMessage: String?
    @State private var detailRecord: SimultaneousTranslationRecord?
    @State private var sharePayload: SharePayload?
    @State private var exportDirectory: URL?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                navigationBar

                if records.isEmpty {
                    Spacer()
                    Text(L10n.t("暂无同声传译记录", "No interpretation records"))
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
                    actionBar
                }
            }

            if showsDeleteConfirm {
                deleteConfirmationSheet
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .onAppear { reload() }
        .compatibleNavigationDestination(item: $detailRecord) { record in
            TranslationRecordDetailView(record: record)
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
            Text(selectionMode ? L10n.t("已选择\(selectedIds.count)项", "\(selectedIds.count) Selected") : L10n.t("同声传译记录", "Interpretation History"))
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
                            toggleSelectAll()
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

    private var actionBar: some View {
        TranslationRecordSelectionBar(
            hasSelection: !selectedIds.isEmpty,
            onDelete: { showsDeleteConfirm = true },
            onShare: shareSelection
        )
    }

    private func recordRow(_ record: SimultaneousTranslationRecord) -> some View {
        Button {
            if selectionMode {
                toggleSelection(record.id)
            } else {
                detailRecord = record
            }
        } label: {
            HStack(spacing: 10) {
                if selectionMode {
                    Image(systemName: selectedIds.contains(record.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(
                            selectedIds.contains(record.id)
                                ? AppTheme.accent
                                : Color(red: 0.78, green: 0.78, blue: 0.78)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(record.title)
                        .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)

                    Text(record.sourceText.replacingOccurrences(of: "\n", with: " "))
                        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)

                    Text(metaText(for: record))
                        .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .buttonStyle(.plain)
    }

    private func metaText(for record: SimultaneousTranslationRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        let date = formatter.string(from: Date(timeIntervalSince1970: record.createdAt))
        return L10n.t("语言：", "Languages: ") + "\(TranslationLanguage.fromDisplayName(record.sourceLanguage).displayName)-\(TranslationLanguage.fromDisplayName(record.targetLanguage).displayName)  \(date)"
    }

    private func reload() {
        records = SimultaneousTranslationRecordStore.getAll()
    }

    private func enterSelectionMode() {
        selectionMode = true
        selectedIds.removeAll()
    }

    private func exitSelectionMode() {
        selectionMode = false
        selectedIds.removeAll()
    }

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private var allRecordsSelected: Bool {
        !records.isEmpty && selectedIds.count == records.count
    }

    private func toggleSelectAll() {
        selectedIds = allRecordsSelected ? [] : Set(records.map(\.id))
    }

    private var deleteConfirmationSheet: some View {
        TranslationRecordDeleteConfirmation(
            count: selectedIds.count,
            onCancel: { showsDeleteConfirm = false },
            onDelete: {
                SimultaneousTranslationRecordStore.delete(ids: selectedIds)
                showsDeleteConfirm = false
                exitSelectionMode()
                reload()
            }
        )
        .zIndex(10)
    }

    private func shareSelection() {
        let selected = records.filter { selectedIds.contains($0.id) }
        guard !selected.isEmpty else { return }
        let text = selected.map { record in
            "\(record.title)\n\(metaText(for: record))\n\n\(record.sourceText)\n\n\(record.targetText)"
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

}

#Preview {
    CompatibleNavigationStack {
        TranslationRecordListView()
    }
}
