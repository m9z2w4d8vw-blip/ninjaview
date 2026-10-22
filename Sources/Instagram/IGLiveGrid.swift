import AVFoundation
import Foundation
import SwiftUI

// MARK: - Live grid model

/// Loads an Instagram profile's post grid via the signed-in session so thumbnails
/// can be shown inline on the profile screen without archiving first.
@MainActor
final class IGLiveGridModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [IGGridItem] = []
    @Published private(set) var total = 0

    private var session: IGSession?
    private var ownsSession = false

    func load(_ handle: String) async {
        guard phase == .idle else { return }
        guard IGCredentials.shared.isSignedIn else { return }
        phase = .loading

        // Reuse the archiver's session when it's already running to avoid a second WKWebView.
        if IGPostArchiver.shared.isRunning {
            session = IGPostArchiver.shared.sharedSession()
            ownsSession = false
        } else {
            session = IGSession()
            ownsSession = true
        }
        guard let s = session else { phase = .idle; return }

        guard await s.ensureSignedIn() else {
            let msg: String
            switch s.phase {
            case .challenge:
                msg = "Instagram wants to verify you. Open Settings \u{203A} Instagram to finish."
            case .loginFailed(let why):
                msg = why.isEmpty ? "Couldn't sign in to Instagram." : why
            default:
                msg = "Couldn't sign in to Instagram."
            }
            phase = .failed(msg)
            cleanup()
            return
        }

        // Quick load: 4 idle rounds × 2.5 s = ~10 s max idle wait.
        // The first API batch typically arrives in 3–5 s, so most profiles finish quickly.
        guard let grid = await s.readGrid(handle, maxMinutes: 2, idleRounds: 4) else {
            phase = .failed("Couldn't load posts. Try again.")
            cleanup()
            return
        }

        items = grid.items
        total = grid.total
        phase = .ready
        cleanup()
    }

    func retry(_ handle: String) async {
        phase = .idle
        items = []
        total = 0
        await load(handle)
    }

    private func cleanup() {
        if ownsSession, let s = session {
            s.teardown()
            session = nil
        }
    }
}

// MARK: - Live post detail sheet

/// Shows one live Instagram post (media + caption) loaded via the signed-in session.
/// Supports photo carousels (swipe left/right) and videos.
@MainActor
struct IGLivePostSheet: View {
    let handle: String
    let gridItem: IGGridItem
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloads: DownloadCenter
    @StateObject private var player = ClipPlayer()
    @State private var detail: IGPostDetail? = nil
    @State private var loading = true
    @State private var error: String? = nil
    @State private var mediaIndex = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.nvPaper.ignoresSafeArea()
                if loading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.nvMuted)
                        Text("Loading post")
                            .font(.subheadline)
                            .foregroundStyle(Color.nvMuted)
                    }
                } else if let err = error {
                    ContentUnavailableView {
                        Label("Couldn't load post", systemImage: "exclamationmark.triangle")
                    } description: { Text(err) }
                } else if let d = detail {
                    postContent(d)
                }
            }
            .navigationTitle("@\(handle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await fetchPost() }
        .onDisappear { player.stop() }
    }

    // MARK: Post content

    @ViewBuilder private func postContent(_ d: IGPostDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                mediaView(d)
                actionsRow(d)
                infoBlock(d)
            }
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder private func mediaView(_ d: IGPostDetail) -> some View {
        let current = d.media.indices.contains(mediaIndex) ? d.media[mediaIndex] : nil
        ZStack {
            Color.black
            if let m = current {
                if m.isVideo {
                    ZStack {
                        if let poster = m.posterURL {
                            RemoteImage(poster, maxPixel: 900, mode: .fit, placeholder: .clear)
                        }
                        PlayerSurface(player: player.player)
                        if !player.isReady {
                            ProgressView().tint(.white)
                        }
                        // Mute indicator
                        Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.6), in: Circle())
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .allowsHitTesting(false)
                    }
                    .task(id: mediaIndex) {
                        if let url = m.mediaURL {
                            player.load(url)
                            player.isMuted = false
                            player.play()
                        }
                    }
                    .onTapGesture { player.isMuted.toggle() }
                } else if let url = m.mediaURL {
                    RemoteImage(url, maxPixel: 1600, mode: .fit, placeholder: .clear)
                }
            }
            // Carousel badge
            if d.media.count > 1 {
                Text("\(mediaIndex + 1)/\(d.media.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { v in
                guard abs(v.translation.width) > 40, abs(v.translation.width) > abs(v.translation.height) else { return }
                if v.translation.width < 0, mediaIndex + 1 < d.media.count {
                    mediaIndex += 1; player.stop()
                } else if v.translation.width > 0, mediaIndex > 0 {
                    mediaIndex -= 1; player.stop()
                }
            }
        )
    }

    private func actionsRow(_ d: IGPostDetail) -> some View {
        HStack(spacing: 20) {
            if d.media.count > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<min(d.media.count, 10), id: \.self) { i in
                        Circle()
                            .fill(i == mediaIndex ? Color.nvInk : Color.nvRule)
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            // Save current media
            if let m = d.media.indices.contains(mediaIndex) ? d.media[mediaIndex] : nil,
               let url = m.mediaURL {
                Button {
                    downloads.fetch(url, kind: m.isVideo ? .video : .photo, baseName: "instagram-\(handle)")
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .accessibilityLabel("Save to Photos")
            }
            // Share
            if let m = d.media.indices.contains(mediaIndex) ? d.media[mediaIndex] : nil,
               let url = m.mediaURL {
                Button {
                    downloads.share(url, kind: m.isVideo ? .video : .photo, baseName: "instagram-\(handle)")
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
            }
        }
        .font(.system(size: 22))
        .foregroundStyle(Color.nvInk)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func infoBlock(_ d: IGPostDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if d.likes > 0 {
                Text("\(d.likes) likes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.nvInk)
            }
            if !d.caption.isEmpty {
                (Text(handle).fontWeight(.semibold) + Text(" \(d.caption)"))
                    .font(.subheadline)
                    .foregroundStyle(Color.nvInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .tint(Color.nvLink)
            }
            if !d.date.isEmpty, let when = liveParseISO8601(d.date) {
                Text(when.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(Color.nvMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    // MARK: Loading

    private func fetchPost() async {
        let s: IGSession
        let owns: Bool
        if IGPostArchiver.shared.isRunning {
            s = IGPostArchiver.shared.sharedSession()
            owns = false
        } else {
            s = IGSession()
            owns = true
        }
        guard await s.ensureSignedIn() else {
            error = "Couldn't sign in. Check Settings \u{203A} Instagram."
            loading = false
            if owns { s.teardown() }
            return
        }
        let d = await s.readPost(gridItem.code, comments: false)
        if owns { s.teardown() }
        loading = false
        if let d {
            detail = d
        } else {
            error = "Couldn't load this post."
        }
    }
}

/// ISO 8601 parser for Instagram's fractional-seconds timestamps.
private func liveParseISO8601(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
        f.formatOptions = opts
        if let d = f.date(from: s) { return d }
    }
    return nil
}
