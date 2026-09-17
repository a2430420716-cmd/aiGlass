import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FeedbackMediaItem: Identifiable {
    let id = UUID()
    var thumbnail: UIImage
    var uploadedFileID: String?
    var isVideo: Bool
    var isUploading: Bool
    var uploadFailed: Bool
}

struct FeedbackPickedMedia {
    let data: Data
    let fileName: String
    let mimeType: String
    let thumbnail: UIImage
    let isVideo: Bool
}

enum FeedbackMediaPickerAction: Identifiable, Equatable {
    case cameraPhoto
    case cameraVideo
    case photoLibrary

    var id: String {
        switch self {
        case .cameraPhoto: "cameraPhoto"
        case .cameraVideo: "cameraVideo"
        case .photoLibrary: "photoLibrary"
        }
    }
}

struct FeedbackMediaSourceSheet: View {
    let onCamera: () -> Void
    let onRecordVideo: () -> Void
    let onPhotoLibrary: () -> Void
    let onCancel: () -> Void

    private var showsCamera: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsCamera {
                FeedbackMediaSheetActionButton(title: L10n.t("拍照", "Take Photo"), action: onCamera)
                FeedbackMediaSheetDivider()
                FeedbackMediaSheetActionButton(title: L10n.t("录制视频", "Record Video"), action: onRecordVideo)
                FeedbackMediaSheetDivider()
            }

            FeedbackMediaSheetActionButton(title: L10n.t("从相册中选择", "Choose from Library"), action: onPhotoLibrary)

            FeedbackMediaSheetCancelButton(action: onCancel)
                .padding(.top, 20)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardBackground)
    }
}

enum FeedbackMediaThumbnailFactory {
    static func thumbnail(for image: UIImage) -> UIImage {
        image.preparingThumbnail(of: CGSize(width: 176, height: 176)) ?? image
    }

    static func thumbnail(forVideoAt url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 176, height: 176)

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            print("[feedback-media] video thumbnail failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func pickedMedia(from image: UIImage, fileName: String = "feedback.jpg") -> FeedbackPickedMedia? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        return FeedbackPickedMedia(
            data: data,
            fileName: fileName,
            mimeType: "image/jpeg",
            thumbnail: thumbnail(for: image),
            isVideo: false
        )
    }

    static func pickedMedia(fromVideoURL url: URL) -> FeedbackPickedMedia? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let fileName = "feedback.\(ext.isEmpty ? "mov" : ext)"
        let mimeType = ext == "mp4" ? "video/mp4" : "video/quicktime"
        let thumbnail = thumbnail(forVideoAt: url) ?? UIImage(systemName: "video.fill") ?? UIImage()
        return FeedbackPickedMedia(
            data: data,
            fileName: fileName,
            mimeType: mimeType,
            thumbnail: thumbnail,
            isVideo: true
        )
    }
}

struct FeedbackCameraPicker: UIViewControllerRepresentable {
    enum Mode {
        case photo
        case video
    }

    let mode: Mode
    let onPicked: (FeedbackPickedMedia) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false

        switch mode {
        case .photo:
            picker.mediaTypes = [UTType.image.identifier]
            picker.cameraCaptureMode = .photo
        case .video:
            picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video
            picker.videoQuality = .typeMedium
        }

        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: FeedbackCameraPicker

        init(parent: FeedbackCameraPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            defer { parent.dismiss() }

            if let image = info[.originalImage] as? UIImage,
               let media = FeedbackMediaThumbnailFactory.pickedMedia(from: image) {
                parent.onPicked(media)
                return
            }

            if let url = info[.mediaURL] as? URL,
               let media = FeedbackMediaThumbnailFactory.pickedMedia(fromVideoURL: url) {
                parent.onPicked(media)
            }
        }
    }
}

struct FeedbackMediaLibraryPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onPicked: ([FeedbackPickedMedia]) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = max(selectionLimit, 1)
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: FeedbackMediaLibraryPicker

        init(parent: FeedbackMediaLibraryPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }

            Task {
                var picked: [FeedbackPickedMedia] = []
                for result in results {
                    if let media = await Self.loadMedia(from: result.itemProvider) {
                        picked.append(media)
                    }
                }
                guard !picked.isEmpty else { return }
                await MainActor.run {
                    parent.onPicked(picked)
                }
            }
        }

        private static func loadMedia(from provider: NSItemProvider) async -> FeedbackPickedMedia? {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                return await loadImage(from: provider)
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                return await loadVideo(from: provider)
            }
            return nil
        }

        private static func loadImage(from provider: NSItemProvider) async -> FeedbackPickedMedia? {
            await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage,
                       let media = FeedbackMediaThumbnailFactory.pickedMedia(from: image) {
                        continuation.resume(returning: media)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        private static func loadVideo(from provider: NSItemProvider) async -> FeedbackPickedMedia? {
            await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)

                    do {
                        if FileManager.default.fileExists(atPath: tempURL.path) {
                            try FileManager.default.removeItem(at: tempURL)
                        }
                        try FileManager.default.copyItem(at: url, to: tempURL)
                        let media = FeedbackMediaThumbnailFactory.pickedMedia(fromVideoURL: tempURL)
                        continuation.resume(returning: media)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

struct FeedbackMediaThumbnailView: View {
    let item: FeedbackMediaItem
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Image(uiImage: item.thumbnail)
                    .resizable()
                    .scaledToFill()

                if item.isUploading {
                    Color.black.opacity(0.35)
                    ProgressView()
                        .tint(.white)
                }

                if item.uploadFailed {
                    Color.black.opacity(0.35)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                }

                if item.isVideo {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                            Spacer()
                        }
                        .padding(6)
                    }
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .clipped()

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
    }
}

// Sheet button styles for feedback media source picker.
private struct FeedbackMediaSheetActionButton: View {
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

private struct FeedbackMediaSheetDivider: View {
    var body: some View {
        Divider()
            .overlay(Color(red: 0.94, green: 0.94, blue: 0.94))
    }
}

private struct FeedbackMediaSheetCancelButton: View {
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
