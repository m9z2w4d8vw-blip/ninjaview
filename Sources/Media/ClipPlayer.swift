import AVFoundation
import SwiftUI
import UIKit

/// One AVPlayer per list of posts; the post in the middle of the screen plays through it.
@MainActor
final class ClipPlayer: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var failure: String? = nil
    @Published var isMuted = true {
        didSet { player.isMuted = isMuted }
    }

    private var url: URL?
    private var loadStarted = Date()
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var timeObserver: Any?

    private var backgroundObserver: NSObjectProtocol?

    init() {
        player.actionAtItemEnd = .none
        player.isMuted = true
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let item = self.player.currentItem else { return }
                let duration = item.duration.seconds
                guard duration.isFinite, duration > 0 else { return }
                if self.duration != duration { self.duration = duration }
                self.progress = min(1, max(0, time.seconds / duration))
            }
        }
    }

    /// Time left, Instagram style ("0:59").
    var remainingText: String? {
        guard duration > 0 else { return nil }
        let left = max(0, Int((duration * (1 - progress)).rounded()))
        return String(format: "%d:%02d", left / 60, left % 60)
    }

    func load(_ url: URL) {
        guard self.url != url else { return }
        self.url = url
        failure = nil
        isReady = false
        progress = 0
        duration = 0
        loadStarted = Date()
        DebugLog.shared.add(.player, "Loading \(url.isFileURL ? "saved file \(url.lastPathComponent)" : "video from \(url.host ?? "?")")")
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
                    DebugLog.shared.add(.player, "Ready to play after \(Int(Date().timeIntervalSince(self.loadStarted) * 1000)) ms")
                case .failed:
                    self.failure = message ?? "This video couldn't be played."
                    DebugLog.shared.error(.player, "Playback failed: \(message ?? "unknown error")")
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
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { _ in
            Task { @MainActor in DebugLog.shared.warn(.player, "Playback stalled, waiting on the network") }
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
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
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
