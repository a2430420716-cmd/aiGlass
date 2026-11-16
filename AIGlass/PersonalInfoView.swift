import SwiftUI
import UIKit

struct PersonalInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authSession: AuthSession

    @State private var showAvatarSourceSheet = false
    @State private var pendingImagePickerSource: AvatarImagePicker.Source?
    @State private var imagePickerRequest: ImagePickerRequest?
    @State private var avatarPreviewImage: UIImage?
    @State private var isSaving = false
    @State private var alertMessage: String?

    private var nickname: String {
        let value = authSession.userInfo?.nickname.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? L10n.t("用户", "User") : value
    }

    private var phoneNumber: String {
        let value = authSession.userInfo?.phone ?? authSession.phoneNumber ?? L10n.t("未绑定手机号", "No phone linked")
        return AuthAccountIdentifier.maskPhoneForDisplay(value)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    infoCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .suppressTabBarOnAppear()
        .overlay {
            if isSaving {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView {
                        Text(L10n.t("保存中...", "Saving..."))
                            .font(AppTheme.notoSansSC(size: 14, weight: .regular))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                    .tint(AppTheme.primaryText)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(AppTheme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .sheet(isPresented: $showAvatarSourceSheet, onDismiss: presentPendingImagePicker) {
            AvatarSourceSheet(
                onCamera: {
                    pendingImagePickerSource = .camera
                    showAvatarSourceSheet = false
                },
                onPhotoLibrary: {
                    pendingImagePickerSource = .photoLibrary
                    showAvatarSourceSheet = false
                },
                onCancel: {
                    pendingImagePickerSource = nil
                    showAvatarSourceSheet = false
                }
            )
            .compatiblePresentationDetents([.height(220)])
            .compatiblePresentationDragIndicator(.hidden)
            .compatiblePresentationCornerRadius(32)
            .compatiblePresentationBackground(AppTheme.cardBackground)
        }
        .fullScreenCover(item: $imagePickerRequest) { request in
            AvatarImagePicker(source: request.source) { image in
                imagePickerRequest = nil
                uploadAvatar(image)
            }
            .ignoresSafeArea()
        }
        .alert(L10n.t("提示", "Notice"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .task {
            await authSession.refreshUserInfo()
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(L10n.t("个人资料", "Personal Info"))
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

    private var infoCard: some View {
        VStack(spacing: 0) {
            tappableRow {
                showAvatarSourceSheet = true
            } content: {
                PersonalInfoRow(
                    title: L10n.t("头像", "Profile picture"),
                    showsChevron: true
                ) {
                    ProfileAvatarView(
                        size: 44,
                        imageURL: authSession.userInfo?.headimg,
                        cacheToken: authSession.avatarCacheToken,
                        previewImage: avatarPreviewImage ?? authSession.localAvatarImage
                    )
                }
            }

            PersonalInfoDivider()

            NavigationLink {
                EditUsernameView(initialNickname: authSession.userInfo?.nickname ?? "")
                    .environmentObject(authSession)
            } label: {
                PersonalInfoRow(
                    title: L10n.t("用户名", "Username"),
                    value: nickname,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            .disabled(isSaving)

            PersonalInfoDivider()

            PersonalInfoRow(
                title: L10n.t("手机号", "Phone number"),
                value: phoneNumber,
                showsChevron: false
            )
        }
        .padding(.horizontal, 16)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func tappableRow<Content: View>(
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    private func presentPendingImagePicker() {
        guard let pending = pendingImagePickerSource else { return }
        pendingImagePickerSource = nil

        let request: ImagePickerRequest = pending == .camera ? .camera : .photoLibrary
        // 等来源 sheet 完全消失后再弹相机，避免 UIImagePicker 落到相册。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            imagePickerRequest = request
        }
    }

    private func uploadAvatar(_ image: UIImage) {
        guard !isSaving else { return }
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            alertMessage = L10n.t("图片处理失败", "Failed to process image")
            return
        }

        avatarPreviewImage = image
        // 同步到会话，回「我的」页立即显示新头像
        authSession.setLocalAvatarImage(image)
        isSaving = true
        Task {
            do {
                let headimg = try await authSession.uploadAvatarImage(data)
                let currentNickname = authSession.userInfo?.nickname.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try await authSession.saveUserProfile(
                    nickname: nicknameForSave(currentNickname),
                    headimg: headimg
                )
                avatarPreviewImage = nil
                isSaving = false
            } catch {
                avatarPreviewImage = nil
                authSession.setLocalAvatarImage(nil)
                isSaving = false
                alertMessage = error.localizedDescription
            }
        }
    }

    private func nicknameForSave(_ nickname: String) -> String {
        if !nickname.isEmpty {
            return nickname
        }
        let phone = authSession.userInfo?.phone.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !phone.isEmpty {
            return phone
        }
        return "用户"
    }
}

private enum ImagePickerRequest: Identifiable {
    case camera
    case photoLibrary

    var id: String {
        switch self {
        case .camera: "camera"
        case .photoLibrary: "photoLibrary"
        }
    }

    var source: AvatarImagePicker.Source {
        switch self {
        case .camera: .camera
        case .photoLibrary: .photoLibrary
        }
    }
}

private struct AvatarSourceSheet: View {
    let onCamera: () -> Void
    let onPhotoLibrary: () -> Void
    let onCancel: () -> Void

    private var showsCamera: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsCamera {
                ProfileSheetActionButton(title: L10n.t("拍照", "Take photo"), action: onCamera)
                ProfileSheetDivider()
            }

            ProfileSheetActionButton(title: L10n.t("从相册中选择", "Choose from gallery"), action: onPhotoLibrary)

            ProfileSheetCancelButton(action: onCancel)
                .padding(.top, 20)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardBackground)
    }
}

private struct ProfileSheetActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTheme.notoSansSC(size: 16, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
        }
        .buttonStyle(.plain)
    }
}

private struct ProfileSheetDivider: View {
    var body: some View {
        Divider()
            .overlay(Color(red: 0.94, green: 0.94, blue: 0.94))
    }
}

private struct ProfileSheetCancelButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(L10n.t("取消", "Cancel"))
                .font(AppTheme.notoSansSC(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ProfileAvatarView: View {
    var size: CGFloat = 64
    var imageURL: String? = nil
    var cacheToken: String? = nil
    var previewImage: UIImage? = nil

    @State private var remoteImage: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
            } else if let remoteImage {
                Image(uiImage: remoteImage)
                    .resizable()
                    .scaledToFill()
            } else if loadFailed || displayURL == nil {
                placeholder
            } else {
                ZStack {
                    placeholder
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear {
            // 首帧先吃 URLCache，避免等 .task 才出图闪 placeholder
            if remoteImage == nil, previewImage == nil {
                remoteImage = AvatarImageCache.cachedImage(for: imageURL)
            }
        }
        // cacheToken 只作重载 key，不拼进 URL（避免 OSS 拒未知 query）
        .task(id: loadKey) {
            await loadRemoteImage()
        }
    }

    private var displayURL: URL? {
        MediaURLResolver.url(for: imageURL)
    }

    private var loadKey: String {
        let url = displayURL?.absoluteString ?? ""
        let token = cacheToken ?? ""
        return "\(url)|\(token)"
    }

    private func loadRemoteImage() async {
        loadFailed = false
        guard previewImage == nil, let url = displayURL else { return }

        // 优先同步命中 URLCache，避免切 tab / 重登先闪 placeholder
        if let cached = AvatarImageCache.cachedImage(for: imageURL) {
            remoteImage = cached
            return
        }

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            AppRequestHeaders.apply(to: &request)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status), let image = UIImage(data: data) else {
                if remoteImage == nil {
                    loadFailed = true
                }
                return
            }
            remoteImage = image
        } catch {
            if remoteImage == nil {
                loadFailed = true
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.85, green: 0.92, blue: 1.0),
                            Color(red: 0.95, green: 0.88, blue: 0.95)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: "person.fill")
                .font(.system(size: size * 0.5))
                .foregroundStyle(Color(red: 0.45, green: 0.55, blue: 0.75))
        }
    }
}

private struct AvatarImagePicker: UIViewControllerRepresentable {
    enum Source {
        case camera
        case photoLibrary

        var uiSourceType: UIImagePickerController.SourceType {
            switch self {
            case .camera: .camera
            case .photoLibrary: .photoLibrary
            }
        }
    }

    let source: Source
    let onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        let sourceType = source.uiSourceType

        guard UIImagePickerController.isSourceTypeAvailable(sourceType) else {
            print("[AvatarImagePicker] source unavailable: \(sourceType.rawValue)")
            picker.sourceType = .photoLibrary
            picker.delegate = context.coordinator
            picker.allowsEditing = true
            return picker
        }

        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = true

        if sourceType == .camera {
            picker.cameraCaptureMode = .photo
            picker.modalPresentationStyle = .fullScreen
        }

        print("[AvatarImagePicker] presenting source=\(sourceType.rawValue)")
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        let sourceType = source.uiSourceType
        guard uiViewController.sourceType != sourceType,
              UIImagePickerController.isSourceTypeAvailable(sourceType) else {
            return
        }
        uiViewController.sourceType = sourceType
        if sourceType == .camera {
            uiViewController.cameraCaptureMode = .photo
        }
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: AvatarImagePicker

        init(parent: AvatarImagePicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage
            parent.dismiss()
            if let image {
                parent.onImagePicked(image)
            }
        }
    }
}

private struct PersonalInfoRow<Trailing: View>: View {
    let title: String
    var value: String?
    var showsChevron: Bool
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        value: String? = nil,
        showsChevron: Bool,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.value = value
        self.showsChevron = showsChevron
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(AppTheme.notoSansSC(size: 15, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            trailing()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct PersonalInfoDivider: View {
    var body: some View {
        Divider()
            .overlay(Color(red: 0.94, green: 0.94, blue: 0.94))
    }
}

#Preview {
    CompatibleNavigationStack {
        PersonalInfoView()
            .environmentObject(AuthSession())
    }
}
