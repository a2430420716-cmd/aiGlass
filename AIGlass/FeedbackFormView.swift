import SwiftUI

struct FeedbackFormView: View {
    private let maxMediaCount = 9

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession

    @State private var feedbackText = ""
    @State private var selectedCategoryID: Int?
    @State private var contactInfo = ""
    @State private var problemClasses: [ProblemClassItem] = []
    @State private var isLoadingProblemClasses = false
    @State private var mediaItems: [FeedbackMediaItem] = []
    @State private var showMediaSourceSheet = false
    @State private var pendingMediaPickerAction: FeedbackMediaPickerAction?
    @State private var cameraPickerAction: FeedbackMediaPickerAction?
    @State private var showMediaLibraryPicker = false
    @State private var alertMessage: String?
    @State private var serialUploadTask: Task<Void, Never>?
    @State private var isSubmitting = false
    @State private var showsSuccessToast = false
    @State private var submitTask: Task<Void, Never>?
    @FocusState private var focusedField: FocusField?

    private enum FocusField: Hashable {
        case feedback
        case contact
    }

    private let maxCharacters = 300

    private var remainingMediaSlots: Int {
        max(0, maxMediaCount - mediaItems.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    feedbackInputSection
                    categorySection
                    mediaUploadSection
                    contactSection
                    submitButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .dismissKeyboardOnVerticalDrag(perform: dismissKeyboard)
        .task {
            await loadProblemClass()
        }
        .sheet(isPresented: $showMediaSourceSheet, onDismiss: presentPendingMediaPicker) {
            FeedbackMediaSourceSheet(
                onCamera: {
                    pendingMediaPickerAction = .cameraPhoto
                    showMediaSourceSheet = false
                },
                onRecordVideo: {
                    pendingMediaPickerAction = .cameraVideo
                    showMediaSourceSheet = false
                },
                onPhotoLibrary: {
                    pendingMediaPickerAction = .photoLibrary
                    showMediaSourceSheet = false
                },
                onCancel: {
                    pendingMediaPickerAction = nil
                    showMediaSourceSheet = false
                }
            )
            .compatiblePresentationDetents([.height(280)])
            .compatiblePresentationDragIndicator(.hidden)
            .compatiblePresentationCornerRadius(32)
            .compatiblePresentationBackground(AppTheme.cardBackground)
        }
        .fullScreenCover(item: $cameraPickerAction) { action in
            switch action {
            case .cameraPhoto:
                FeedbackCameraPicker(mode: .photo) { media in
                    cameraPickerAction = nil
                    handlePickedMedia([media])
                }
                .ignoresSafeArea()
            case .cameraVideo:
                FeedbackCameraPicker(mode: .video) { media in
                    cameraPickerAction = nil
                    handlePickedMedia([media])
                }
                .ignoresSafeArea()
            case .photoLibrary:
                EmptyView()
            }
        }
        .sheet(isPresented: $showMediaLibraryPicker) {
            FeedbackMediaLibraryPicker(selectionLimit: remainingMediaSlots) { mediaList in
                showMediaLibraryPicker = false
                handlePickedMedia(mediaList)
            }
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .overlay {
            if showsSuccessToast {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()

                    VStack(spacing: 30) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.19, green: 0.78, blue: 0.42))
                                .frame(width: 96, height: 96)
                            Image(systemName: "checkmark")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                        Text(L10n.t("反馈完成", "Feedback submitted"))
                            .font(AppTheme.notoSansSC(size: 24, weight: .bold))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 330)
                    .background(AppTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .padding(.horizontal, 28)
                }
                .transition(.opacity)
            }
        }
        .onDisappear {
            serialUploadTask?.cancel()
            submitTask?.cancel()
        }
    }

    private func presentPendingMediaPicker() {
        guard let pending = pendingMediaPickerAction else { return }
        pendingMediaPickerAction = nil

        guard remainingMediaSlots > 0 else {
            alertMessage = L10n.t(
                "最多上传\(maxMediaCount)张图片或者视频",
                "You can upload up to \(maxMediaCount) photos or videos"
            )
            return
        }

        switch pending {
        case .cameraPhoto, .cameraVideo:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                cameraPickerAction = pending
            }
        case .photoLibrary:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                showMediaLibraryPicker = true
            }
        }
    }

    private func handlePickedMedia(_ mediaList: [FeedbackPickedMedia]) {
        let allowedCount = min(mediaList.count, remainingMediaSlots)
        guard allowedCount > 0 else {
            alertMessage = L10n.t(
                "最多上传\(maxMediaCount)张图片或者视频",
                "You can upload up to \(maxMediaCount) photos or videos"
            )
            return
        }

        if mediaList.count > allowedCount {
            alertMessage = L10n.t(
                "最多上传\(maxMediaCount)张图片或者视频",
                "You can upload up to \(maxMediaCount) photos or videos"
            )
        }

        var batch: [(UUID, FeedbackPickedMedia)] = []
        for media in mediaList.prefix(allowedCount) {
            let item = FeedbackMediaItem(
                thumbnail: media.thumbnail,
                uploadedFileID: nil,
                isVideo: media.isVideo,
                isUploading: true,
                uploadFailed: false
            )
            mediaItems.append(item)
            batch.append((item.id, media))
        }
        scheduleSerialUploads(batch)
    }

    private func scheduleSerialUploads(_ batch: [(UUID, FeedbackPickedMedia)]) {
        let previous = serialUploadTask
        serialUploadTask = Task {
            if let previous { await previous.value }
            await uploadMediaItemsSerially(batch)
        }
    }

    @MainActor
    private func uploadMediaItemsSerially(_ items: [(UUID, FeedbackPickedMedia)]) async {
        guard let token = authSession.token, !token.isEmpty else {
            for (itemID, _) in items {
                updateMediaItem(id: itemID) { $0.isUploading = false; $0.uploadFailed = true }
            }
            alertMessage = L10n.t("登录凭证缺失，请重新登录", "Session expired. Please sign in again")
            return
        }

        for (itemID, media) in items {
            guard !Task.isCancelled else { return }

            do {
                let response = try await UploadService.uploadFile(
                    fileData: media.data,
                    fileName: media.fileName,
                    mimeType: media.mimeType,
                    token: token
                )
                updateMediaItem(id: itemID) {
                    $0.uploadedFileID = response.id
                    $0.isUploading = false
                    $0.uploadFailed = false
                }
            } catch {
                updateMediaItem(id: itemID) {
                    $0.isUploading = false
                    $0.uploadFailed = true
                }
                alertMessage = error.localizedDescription
            }
        }
    }

    private func updateMediaItem(id: UUID, update: (inout FeedbackMediaItem) -> Void) {
        guard let index = mediaItems.firstIndex(where: { $0.id == id }) else { return }
        update(&mediaItems[index])
    }

    private func removeMediaItem(id: UUID) {
        mediaItems.removeAll { $0.id == id }
    }

    private func loadProblemClass() async {
        guard let token = authSession.token, !token.isEmpty else {
            print("[get_problem_class] skipped: missing token")
            return
        }

        isLoadingProblemClasses = true
        defer { isLoadingProblemClasses = false }

        do {
            problemClasses = try await ProblemService.fetchProblemClass(token: token)
        } catch {
            print("[get_problem_class] failed: \(error.localizedDescription)")
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("问题反馈", "Feedback"))
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

    private var feedbackInputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormSectionTitle(title: L10n.t("问题反馈", "Feedback"), required: true)

            ZStack(alignment: .bottomTrailing) {
                ZStack(alignment: .topLeading) {
                    if feedbackText.isEmpty {
                        Text(L10n.t("描述您遇到的问题", "Describe the issue you encountered"))
                            .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }

                    TextEditor(text: $feedbackText)
                        .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                        .compatibleScrollContentBackgroundHidden()
                        .compatibleScrollDisabled(true)
                        .focused($focusedField, equals: .feedback)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .onChangeCompat(of: feedbackText) { newValue in
                            if newValue.count > maxCharacters {
                                feedbackText = String(newValue.prefix(maxCharacters))
                            }
                        }
                }
                .frame(minHeight: 140)

                Text(L10n.t("\(feedbackText.count)/\(maxCharacters)字", "\(feedbackText.count)/\(maxCharacters) characters"))
                    .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
            }
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormSectionTitle(title: L10n.t("问题分类", "Category"), required: true)

            if isLoadingProblemClasses, problemClasses.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else if problemClasses.isEmpty {
                Text(L10n.t("暂无问题分类", "No categories yet"))
                    .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                // 标签可多行换行；单个标签文字单行，框随文字变宽
                categoryChips
            }
        }
    }

    private var categoryChips: some View {
        FeedbackChipWrap(spacing: 10) {
            ForEach(problemClasses) { category in
                Button {
                    focusedField = nil
                    selectedCategoryID = selectedCategoryID == category.id ? nil : category.id
                } label: {
                    Text(category.className)
                        .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(AppTheme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            if selectedCategoryID == category.id {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(AppTheme.accent, lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var mediaUploadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormSectionTitle(title: L10n.t("上传图片或者视频", "Upload photos or videos"))

            FeedbackCategoryFlowLayout(spacing: 10) {
                ForEach(mediaItems) { item in
                    FeedbackMediaThumbnailView(item: item) {
                        removeMediaItem(id: item.id)
                    }
                }

                if remainingMediaSlots > 0 {
                    Button {
                        focusedField = nil
                        showMediaSourceSheet = true
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(AppTheme.cardBackground)
                                .frame(width: 88, height: 88)

                            Image(systemName: "plus")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(L10n.t("最多上传9张图片或者视频", "Upload up to 9 photos or videos"))
                .font(AppTheme.notoSansSC(size: 12, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormSectionTitle(title: L10n.t("联系方式", "Contact info"), required: true)

            TextField(
                L10n.t(
                    "填写您的电话或者邮箱，方便我们联系到您",
                    "Enter your phone or email so we can contact you"
                ),
                text: $contactInfo
            )
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .focused($focusedField, equals: .contact)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(AppTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var submitButton: some View {
        Button {
            submitFeedback()
        } label: {
            ZStack {
                Text(L10n.t("提交反馈", "Submit Feedback"))
                    .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .opacity(isSubmitting ? 0 : 1)

                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                canSubmit
                    ? Color(red: 0.20, green: 0.20, blue: 0.20)
                    : Color(red: 0.80, green: 0.80, blue: 0.80)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !contactInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedCategoryID != nil
    }

    private func submitFeedback() {
        guard let token = authSession.token, !token.isEmpty else {
            alertMessage = L10n.t("登录凭证缺失，请重新登录", "Session expired. Please sign in again")
            return
        }

        guard let classID = selectedCategoryID else {
            alertMessage = L10n.t("请选择问题分类", "Please select a category")
            return
        }

        let content = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            alertMessage = L10n.t("请描述您遇到的问题", "Please describe the issue")
            return
        }

        let information = contactInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !information.isEmpty else {
            alertMessage = L10n.t("请填写联系方式", "Please enter contact info")
            return
        }

        guard !isSubmitting else { return }

        focusedField = nil
        isSubmitting = true
        submitTask = Task {
            if let serialUploadTask {
                await serialUploadTask.value
            }

            guard !Task.isCancelled else { return }

            if mediaItems.contains(where: { $0.isUploading }) {
                await MainActor.run {
                    isSubmitting = false
                    alertMessage = L10n.t("文件上传中，请稍候", "Upload in progress. Please wait")
                }
                return
            }

            if mediaItems.contains(where: { $0.uploadFailed }) {
                await MainActor.run {
                    isSubmitting = false
                    alertMessage = L10n.t(
                        "存在上传失败的文件，请删除后重试",
                        "Some files failed to upload. Remove them and try again"
                    )
                }
                return
            }

            let files = mediaItems.compactMap(\.uploadedFileID)

            do {
                try await ProblemService.submitProblem(
                    classID: classID,
                    content: content,
                    information: information,
                    files: files,
                    token: token
                )
                await MainActor.run {
                    isSubmitting = false
                    withAnimation(.easeOut(duration: 0.2)) {
                        showsSuccessToast = true
                    }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    dismiss()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isSubmitting = false
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func dismissKeyboard() {
        focusedField = nil
    }
}

private struct FormSectionTitle: View {
    let title: String
    var required = false

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
                .font(AppTheme.notoSansSC(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)

            if required {
                Text("*")
                    .font(AppTheme.notoSansSC(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
        }
    }
}

/// iOS 15 可用的等宽流式排布（图片缩略图等固定尺寸项）。
private struct FeedbackCategoryFlowLayout<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 72), spacing: spacing, alignment: .leading)],
            alignment: .leading,
            spacing: spacing
        ) {
            content()
        }
    }
}

/// iOS 16+：按固有宽度流式排布；iOS 15 回退 LazyVGrid。
private struct FeedbackChipWrap<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            FeedbackChipLayout(spacing: spacing) {
                content()
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), spacing: spacing, alignment: .leading)],
                alignment: .leading,
                spacing: spacing
            ) {
                content()
            }
        }
    }
}

@available(iOS 16.0, *)
private struct FeedbackChipLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(proposal: proposal, subviews: subviews).positions
        for index in subviews.indices {
            guard index < positions.count else { continue }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + positions[index].x, y: bounds.minY + positions[index].y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            contentWidth = max(contentWidth, x - spacing)
        }

        let height = subviews.isEmpty ? 0 : y + rowHeight
        return (CGSize(width: contentWidth, height: height), positions)
    }
}

#Preview {
    CompatibleNavigationStack {
        FeedbackFormView()
            .environmentObject(AuthSession())
    }
}
