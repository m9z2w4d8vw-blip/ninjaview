import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// One AVPlayer shared by the post viewer; whichever page is current plays through it.
@MainActor
final class ClipPlayer: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var failure: String? = nil
    @Published var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    private var url: URL?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    init() {
        player.actionAtItemEnd = .none
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let item = self.player.currentItem else { return }
                let duration = item.duration.seconds
                guard duration.isFinite, duration > 0 else { return }
                self.progress = min(1, max(0, time.seconds / duration))
            }
        }
    }

    func load(_ url: URL) {
        guard self.url != url else { return }
        self.url = url
        failure = nil
        isReady = false
        progress = 0
        // Same user agent as the page, so the CDN sees an ordinary browser.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": WebFactory.userAgent]])
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isReady = true
                case .failed:
                    self.failure = message ?? "This video couldn't be played."
                    DebugLog.shared.add(.download, "Playback failed: \(message ?? "unknown error")")
                default:
                    break
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.player.seek(to: .zero)
                self.player.play()
            }
        }
        player.replaceCurrentItem(with: item)
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to fraction: Double) {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return }
        player.seek(to: CMTime(seconds: duration * fraction, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        progress = fraction
    }

    func stop() {
        pause()
        player.replaceCurrentItem(with: nil)
        url = nil
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

@MainActor
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// The system player: scrubbing, Picture in Picture and AirPlay.
@MainActor
struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

struct SystemPlayerScreen: View {
    let player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SystemPlayer(player: player)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .padding(.leading, 16)
                .padding(.top, 8)
                .accessibilityLabel("Close player")
            }
    }
}
