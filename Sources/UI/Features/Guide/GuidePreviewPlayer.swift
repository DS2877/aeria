import SwiftUI
import AVFoundation
import UIKit

/// The Guide's mini player — one live channel playing in a small window while
/// the viewer keeps browsing. No controls, never focusable: the guide owns the
/// remote. HLS goes through a bare `AVPlayerLayer`, everything else (raw TS,
/// rtmp…) through VLC, the same split as the full-screen player.
///
/// The stream is torn down the moment the view leaves the hierarchy — many
/// IPTV subscriptions allow a single connection, so the preview must never
/// still be holding one when full-screen playback starts.
struct GuidePreviewPlayer: View {
    let item: PlaybackItem

    var body: some View {
        ZStack {
            Color.black
            ProgressView().tint(.white)
            switch PlaybackEngine.choose(for: item.url) {
            case .system: AVPreviewView(url: item.url)
            case .vlc:    VLCPreviewView(item: item)
            }
        }
        .id(item.id)
        .accessibilityHidden(true)
    }
}

/// `AVPlayerLayer`-backed view. Clear until frames arrive, so the spinner
/// underneath shows while the stream opens.
private struct AVPreviewView: UIViewRepresentable {
    let url: URL

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .clear
        let player = AVPlayer(url: url)
        player.automaticallyWaitsToMinimizeStalling = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.playerLayer.player?.replaceCurrentItem(with: nil)
        view.playerLayer.player = nil
    }
}

/// VLC rendering into a plain view, for streams `AVPlayer` can't open.
private struct VLCPreviewView: UIViewRepresentable {
    let item: PlaybackItem

    final class Coordinator {
        var model: VLCPlayerModel?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let model = VLCPlayerModel(item: item) { _, _, _ in }
        context.coordinator.model = model
        model.start(in: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.model?.teardown()
        coordinator.model = nil
    }
}
