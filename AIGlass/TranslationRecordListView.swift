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
                        .padding(.bottom, selectionMode ? 90 : 24)
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

            HStack {
                if selectionMode {
                    Button(allRecordsSelected ? L10n.t("取消全选", "Deselect All") : L10n.t("全选", "Select All")) {
                        toggleSelectAll()
                    }
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
                } else {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(AppTheme.primaryText)
                            .frame(width: 44, height: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if selectionMode {
                    Button(L10n.t("完成", "Done")) {
                        exitSelectionMode()
                    }
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
        Button {
            if selectedIds.isEmpty {
                alertMessage = L10n.t("请选择要删除的记录", "Select records to delete")
            } else {
                showsDeleteConfirm = true
            }
        } label: {
            Label(L10n.t("删除", "Delete"), systemImage: "trash")
                .font(AppTheme.notoSansSC(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(AppTheme.cardBackground)
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
                        .font(.system(size: 20))
                        .foregroundStyle(
                            selectedIds.contains(record.id)
                                ? AppTheme.accent
                                : Color(red: 0.78, green: 0.78, blue: 0.78)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(record.title)
                        .font(AppTheme.notoSansSC(size: 15, weight: .bold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)

                    Text(record.sourceText.replacingOccurrences(of: "\n", with: " "))
                        .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)

                    Text(metaText(for: record))
                        .font(AppTheme.notoSansSC(size: 12, weight: .regular))
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
        return "\(TranslationLanguage.fromDisplayName(record.sourceLanguage).displayName)-\(TranslationLanguage.fromDisplayName(record.targetLanguage).displayName)  \(date)"
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
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture { showsDeleteConfirm = false }

            VStack(spacing: 0) {
                Text(L10n.t("确定删除选中的 \(selectedIds.count) 条记录吗？", "Delete \(selectedIds.count) selected record(s)?"))
                    .font(AppTheme.notoSansSC(size: 17, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)

                Divider()

                HStack(spacing: 12) {
                    Button(L10n.t("取消", "Cancel")) {
                        showsDeleteConfirm = false
                    }
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(red: 0.93, green: 0.93, blue: 0.93))
                    .clipShape(Capsule())

                    Button(L10n.t("删除", "Delete")) {
                        SimultaneousTranslationRecordStore.delete(ids: selectedIds)
                        showsDeleteConfirm = false
                        exitSelectionMode()
                        reload()
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(AppTheme.accent)
                    .clipShape(Capsule())
                }
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .padding(20)
            }
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .transition(.opacity)
        .zIndex(10)
    }
}

#Preview {
    CompatibleNavigationStack {
        TranslationRecordListView()
    }
}
