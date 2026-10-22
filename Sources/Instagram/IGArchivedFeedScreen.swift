import SwiftUI

/// Offline Instagram feed using the same scrolling card layout as TikTok's PostFeedScreen.
/// Both archived stories and posts open here, rather than in a separate black fullscreen player.
@MainActor
struct IGArchivedFeedScreen: View {
    let handle: String
    let items: [IGArchive.Item]
    let stories: Bool
    let start: Int
    @State private var position: Int? = nil
    @State private var commentsIndex: Int? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        IGArchivedCard(handle: handle, item: item, stories: stories,
                                       isCurrent: position == index,
                                       onComments: { commentsIndex = index })
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $position, anchor: .center)
            .onAppear {
                guard !items.isEmpty else { return }
                position = min(max(start, 0), items.count - 1)
                let destination = position
                Task { @MainActor in
                    if let destination { proxy.scrollTo(destination, anchor: .top) }
                }
            }
        }
        .background(Color.nvPaper.ignoresSafeArea())
        .navigationTitle(stories ? "Stories" : "Posts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { commentsIndex != nil }, set: { if !$0 { commentsIndex = nil } })) {
            if let i = commentsIndex, items.indices.contains(i) {
                IGCommentsSheet(handle: handle, post: items[i])
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

@MainActor
private struct IGArchivedCard: View {
    let handle: String
    let item: IGArchive.Item
    let stories: Bool
    let isCurrent: Bool
    let onComments: () -> Void
    @EnvironmentObject private var downloads: DownloadCenter
    @StateObject private var player = ClipPlayer()
    @State private var selected = 0
    @State private var expanded = false

    private var files: [String] { item.files.isEmpty ? [item.file] : item.files }
    private func mediaURL(_ i: Int) -> URL? {
        guard files.indices.contains(i) else { return nil }
        return IGArchive.shared.fileURL(handle, files[i])
    }
    private func isVideo(_ i: Int) -> Bool {
        guard files.indices.contains(i) else { return false }
        let ext = (files[i] as NSString).pathExtension.lowercased()
        return ext == "mp4" || ext == "mov" || (files.count == 1 && item.isVideo)
    }
    private var playbackFile: URL? { isVideo(selected) ? mediaURL(selected) : nil }
    private var preview: [IGArchive.StoredComment] {
        Array(item.comments.filter { $0.parent.isEmpty }.prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RemoteImage(IGArchive.shared.avatarURL(handle), maxPixel: 120)
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(handle).font(.subheadline.weight(.semibold)).foregroundStyle(Color.nvInk)
                    if stories { Text("Story").font(.caption).foregroundStyle(Color.nvMuted) }
                }
                Spacer()
                Menu {
                    if let url = mediaURL(selected) {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.nvInk)
                        .frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ZStack(alignment: .topTrailing) {
                Color.nvCard
                TabView(selection: $selected) {
                    ForEach(Array(files.enumerated()), id: \.offset) { index, _ in
                        ZStack {
                            Color.black.opacity(0.93)
                            if isVideo(index) {
                                if isCurrent && selected == index {
                                    PlayerSurface(player: player.player)
                                    if !player.isReady { ProgressView().tint(.white) }
                                } else {
                                    RemoteImage(IGArchive.shared.fileURL(handle, item.cover), maxPixel: 950, mode: .fit)
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 32)).foregroundStyle(.white)
                                }
                            } else {
                                RemoteImage(mediaURL(index), maxPixel: 1800, mode: .fit, placeholder: .black)
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                if files.count > 1 {
                    Text("\(selected + 1)/\(files.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .aspectRatio(stories ? 9.0 / 16.0 : 4.0 / 5.0, contentMode: .fit)

            HStack(spacing: 18) {
                if !stories {
                    Button(action: onComments) { Image(systemName: "bubble.right") }
                        .accessibilityLabel("Comments")
                }
                if let url = mediaURL(selected) {
                    ShareLink(item: url) { Image(systemName: "paperplane") }
                        .accessibilityLabel("Share")
                }
                Spacer()
                if files.count > 1 { PageDots(count: files.count, index: selected) }
                Spacer(minLength: 0)
                Button(action: save) { Image(systemName: "arrow.down.to.line") }
                    .accessibilityLabel("Save to Photos")
            }
            .font(.system(size: 22))
            .foregroundStyle(Color.nvInk)
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                if !stories {
                    let count = item.expectedComments > 0 ? item.expectedComments : item.comments.count
                    if item.likes > 0 || count > 0 {
                        Text("\(item.likes.formatted()) likes · \(count.formatted()) comments")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.nvInk)
                    }
                    if !item.caption.isEmpty {
                        CaptionText(handle: handle, caption: item.caption, expanded: $expanded)
                    }
                    Button(action: onComments) {
                        Text(count == 0 ? "View comments" : "View all \(count) comments")
                            .font(.subheadline).foregroundStyle(Color.nvMuted)
                    }
                    .buttonStyle(.plain)
                    ForEach(preview, id: \.id) { c in
                        (Text(c.author).fontWeight(.semibold) + Text(" " + c.text))
                            .font(.subheadline).foregroundStyle(Color.nvInk).lineLimit(2)
                    }
                }
                Text(stories ? item.savedAt.formatted(.relative(presentation: .named)) :
                     (item.takenAt.isEmpty ? item.savedAt.formatted(date: .abbreviated, time: .omitted) : (IGArchivedDate.format(item.takenAt) ?? "")))
                    .font(.caption).foregroundStyle(Color.nvMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
        .padding(.bottom, 20)
        .task(id: playbackFile?.absoluteString ?? "") { updatePlayback() }
        .onChange(of: isCurrent) { _, _ in updatePlayback() }
        .onDisappear { player.stop() }
    }

    private func updatePlayback() {
        guard isCurrent, let url = playbackFile else { player.pause(); return }
        player.load(url)
        player.isMuted = false
        player.play()
    }

    private func save() {
        guard let url = mediaURL(selected) else { return }
        downloads.fetch(url, kind: isVideo(selected) ? .video : .photo, baseName: "instagram-\(handle)")
    }
}

private enum IGArchivedDate {
    static func format(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        return d?.formatted(date: .abbreviated, time: .omitted)
    }
}
