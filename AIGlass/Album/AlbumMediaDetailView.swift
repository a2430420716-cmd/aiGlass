import AVKit
import SwiftUI

struct AlbumMediaDetailView: View {
    let item: StoredMediaItem
    @Environment(\.dismiss) private var dismiss

    private let library = MediaLibrary.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if item.isVideo {
                VideoPlayer(player: AVPlayer(url: library.originalURL(for: item)))
                    .ignoresSafeArea()
            } else if let image = UIImage(contentsOfFile: library.originalURL(for: item).path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                Text(L10n.t("无法打开文件", "Unable to open file"))
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 12)
        }
        .onAppear {
            if item.isVideo {
                try? GlassesAudioRouteController.activate(.playback)
            }
        }
        .navigationBarHidden(true)
    }
}
