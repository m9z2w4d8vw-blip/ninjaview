import AVFoundation
import SwiftUI

/// What to show in the full-screen viewer: a run of stories or posts, from the web or from files.
struct IGViewerRequest: Identifiable {
    struct Entry: Identifiable, Hashable {
        let id: String
        let media: URL
        let thumb: URL?
        let isVideo: Bool
        /// Shown under the username, e.g. when an archived story was saved.
        let caption: String
    }

    let id = UUID()
    let handle: String
    let isStories: Bool
    let entries: [Entry]
    let start: Int

    static func live(_ items: [IGItem], handle: String, stories: Bool, start: Int) -> IGViewerRequest {
        let entries = items.compactMap { item -> Entry? in
            guard let media = item.mediaURL else { return nil }
            return Entry(id: item.key, media: media, thumb: item.thumbURL, isVideo: item.isVideo, caption: "")
        }
        return IGViewerRequest(handle: handle, isStories: stories, entries: entries, start: start)
    }

    @MainActor
    static func archived(_ items: [IGArchive.Item], handle: String, stories: Bool, start: Int) -> IGViewerRequest {
        let archive = IGArchive.shared
        let entries = items.compactMap { item -> Entry? in
            guard let media = archive.fileURL(handle, item.file) else { return nil }
            let caption = stories ? "Saved " + item.savedAt.formatted(date: .abbreviated, time: .shortened) : ""
            return Entry(id: item.id, media: media, thumb: archive.fileURL(handle, item.cover), isVideo: item.isVideo, caption: caption)
        }
        return IGViewerRequest(handle: handle, isStories: stories, entries: entries, start: start)
    }
}

/// Full-screen stories and posts. Stories move on by themselves (photos after five seconds,
/// videos when they end). Tap the right side for the next one, the left side to go back,
/// swipe sideways to move, and swipe down to close.
@MainActor
struct IGViewer: View {
    let request: IGViewerRequest
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloads: DownloadCenter
    @StateObject private var player = ClipPlayer()
    @State private var index: Int
    @State private var elapsed: Double = 0
    @State private var paused = false
    @State private var dragOffset: CGFloat = 0

    init(request: IGViewerRequest) {
        self.request = request
        let last = max(0, request.entries.count - 1)
        _index = State(initialValue: min(max(0, request.start), last))
    }

    private var entry: IGViewerRequest.Entry? {
        request.entries.indices.contains(index) ? request.entries[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let entry {
                media(entry)
                    .offset(y: dragOffset)
            } else {
                Text("Nothing to show")
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            tapZones
            VStack(spacing: 10) {
                if request.isStories { progressBars }
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .opacity(dragOffset > 0 ? 0 : 1)
        }
        .gesture(swipes)
        .statusBarHidden()
        .task(id: index) { await play() }
        .onDisappear { player.stop() }
    }

    // MARK: Pieces

    @ViewBuilder private func media(_ entry: IGViewerRequest.Entry) -> some View {
        if entry.isVideo {
            ZStack {
                if !player.isReady, let thumb = entry.thumb {
                    RemoteImage(thumb, maxPixel: 1400, mode: .fit, placeholder: .black)
                }
                PlayerSurface(player: player.player)
                if let failure = player.failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(30)
                } else if !player.isReady {
                    ProgressView()
                        .tint(.white)
                }
            }
        } else {
            RemoteImage(entry.media, maxPixel: 2200, mode: .fit, placeholder: .black)
        }
    }

    private var tapZones: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { previous() }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { next() }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var progressBars: some View {
        if request.entries.count <= 30 {
            HStack(spacing: 3) {
                ForEach(request.entries.indices, id: \.self) { i in
                    bar(fill(i))
                }
            }
        } else {
            HStack(spacing: 8) {
                bar(fill(index))
                Text("\(index + 1) of \(request.entries.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .fixedSize()
            }
        }
    }

    private func bar(_ amount: Double) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.white.opacity(0.35))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: geo.size.width * CGFloat(amount))
                }
        }
        .frame(height: 2.5)
    }

    private func fill(_ i: Int) -> Double {
        if i < index { return 1 }
        if i > index { return 0 }
        return min(1, max(0, elapsed))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            AvatarView(handle: Platform.instagram.key(request.handle))
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.handle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                if let entry, !entry.caption.isEmpty {
                    Text(entry.caption)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            }
            Spacer(minLength: 8)
            if !request.isStories, request.entries.count > 1 {
                Text("\(index + 1) of \(request.entries.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
        .shadow(color: .black.opacity(0.4), radius: 3)
    }

    private var bottomBar: some View {
        HStack(spacing: 22) {
            if request.isStories {
                Button { togglePause() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                }
                .accessibilityLabel(paused ? "Play" : "Pause")
            }
            if entry?.isVideo == true {
                Button { player.isMuted.toggle() } label: {
                    Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .accessibilityLabel(player.isMuted ? "Turn sound on" : "Turn sound off")
            }
            Spacer(minLength: 0)
            Button { save() } label: { Image(systemName: "arrow.down.to.line") }
                .accessibilityLabel("Save to Photos")
            Button { share() } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(Color.white)
        .shadow(color: .black.opacity(0.4), radius: 3)
        .buttonStyle(.plain)
        .frame(height: 44)
    }

    private var swipes: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                let dy = value.translation.height
                if dy > 0, abs(dy) > abs(value.translation.width) { dragOffset = dy }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if dy > 110, abs(dy) > abs(dx) {
                    dismiss()
                    return
                }
                withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                if abs(dx) > 60, abs(dx) > abs(dy) {
                    if dx < 0 { next() } else { previous() }
                }
            }
    }

    // MARK: Playback

    private func play() async {
        elapsed = 0
        guard let entry else { return }
        if entry.isVideo {
            player.load(entry.media)
            player.isMuted = false
            if !paused { player.play() }
        } else {
            player.stop()
        }
        guard request.isStories else { return }
        var last: Double = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
            if paused { continue }
            if entry.isVideo && player.failure == nil {
                guard player.duration > 0 else { continue }
                let now = player.progress
                // The player loops, so the end can show up as a jump back to the start.
                if now >= 0.985 || (last > 0.8 && now < 0.2) {
                    elapsed = 1
                    next()
                    return
                }
                elapsed = now
                last = now
            } else {
                elapsed += 0.05 / 5
                if elapsed >= 1 {
                    next()
                    return
                }
            }
        }
    }

    private func next() {
        if index + 1 < request.entries.count {
            index += 1
        } else {
            dismiss()
        }
    }

    private func previous() {
        if index > 0 {
            index -= 1
        } else {
            elapsed = 0
            if entry?.isVideo == true { player.seek(to: 0) }
        }
    }

    private func togglePause() {
        paused.toggle()
        guard entry?.isVideo == true else { return }
        if paused { player.pause() } else { player.play() }
    }

    private func save() {
        guard let entry else { return }
        downloads.fetch(entry.media, kind: entry.isVideo ? .video : .photo, baseName: "instagram-\(request.handle)")
    }

    private func share() {
        guard let entry else { return }
        downloads.share(entry.media, kind: entry.isVideo ? .video : .photo, baseName: "instagram-\(request.handle)")
    }
}
