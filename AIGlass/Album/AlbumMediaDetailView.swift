import AVKit
import SwiftUI

struct AlbumMediaDetailView: View {
    let item: StoredMediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var playerItemID: UUID?
    @State private var playbackError: String?

    private let library = MediaLibrary.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if item.isVideo {
                AlbumVideoPlayer(player: player)
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
        .overlay(alignment: .bottom) {
            if item.isVideo, let player {
                AlbumVideoControls(player: player)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
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
                prepareVideoPlayer()
            }
        }
        .onChangeCompat(of: item.id) { _ in
            player?.pause()
            player = nil
            playerItemID = nil
            playbackError = nil
            if item.isVideo { prepareVideoPlayer() }
        }
        .onDisappear { player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            guard let failedItem = notification.object as? AVPlayerItem,
                  failedItem === player?.currentItem else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            playbackError = L10n.t("视频播放失败，请重新打开视频。", "Video playback failed. Reopen the video.")
            DebugLogStore.logWiFi("相册视频：播放失败", detail: "file=\(item.fileName) error=\(error?.localizedDescription ?? "unknown")")
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let endedItem = notification.object as? AVPlayerItem,
                  endedItem === player?.currentItem else { return }
            DebugLogStore.logWiFi("相册视频：播放结束", detail: "file=\(item.fileName) storedDuration=\(item.durationSeconds ?? 0) playedTo=\(endedItem.currentTime().seconds) assetDuration=\(endedItem.duration.seconds)")
        }
        .alert(L10n.t("视频播放失败", "Video Playback Failed"), isPresented: Binding(
            get: { playbackError != nil },
            set: { if !$0 { playbackError = nil } }
        )) {
            Button(L10n.t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(playbackError ?? "")
        }
        .navigationBarHidden(true)
    }

    private func prepareVideoPlayer() {
        do {
            try GlassesAudioRouteController.activate(.playback)
        } catch {
            DebugLogStore.logWiFi("相册视频：音频会话失败", detail: "file=\(item.fileName) error=\(error.localizedDescription)")
        }
        guard player == nil || playerItemID != item.id else { return }
        player = AVPlayer(url: library.originalURL(for: item))
        playerItemID = item.id
        DebugLogStore.logWiFi("相册视频：创建播放器", detail: "file=\(item.fileName) storedDuration=\(item.durationSeconds ?? 0)")
    }
}

/// Keep album controls visible instead of relying on AVKit's automatic hiding.
private struct AlbumVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

private struct AlbumVideoControls: View {
    let player: AVPlayer
    @State private var isSeeking = false
    @State private var seekSeconds: Double = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let duration = finiteSeconds(player.currentItem?.duration.seconds ?? 0)
            let current = min(finiteSeconds(player.currentTime().seconds), duration)
            let isPlaying = player.timeControlStatus != .paused
            HStack(spacing: 12) {
                Button {
                    if isPlaying {
                        player.pause()
                    } else if duration > 0, current >= duration {
                        player.seek(to: .zero) { finished in
                            if finished { player.play() }
                        }
                    } else {
                        player.play()
                    }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isPlaying ? L10n.t("暂停", "Pause") : L10n.t("播放", "Play"))

                Text(timeLabel(isSeeking ? seekSeconds : current))
                    .monospacedDigit()
                Slider(value: Binding(
                    get: { isSeeking ? seekSeconds : current },
                    set: { seekSeconds = $0 }
                ), in: 0...max(duration, 1), onEditingChanged: { editing in
                    if editing {
                        seekSeconds = current
                    } else {
                        player.seek(to: CMTime(seconds: seekSeconds, preferredTimescale: 600))
                    }
                    isSeeking = editing
                })
                .disabled(duration <= 0)
                .accessibilityLabel(L10n.t("播放进度", "Playback progress"))
                Text(timeLabel(duration))
                    .monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .tint(.white)
            .padding(.horizontal, 10)
            .background(Color.black.opacity(0.65))
            .cornerRadius(12)
        }
    }

    private func finiteSeconds(_ seconds: Double) -> Double {
        seconds.isFinite ? max(0, seconds) : 0
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
