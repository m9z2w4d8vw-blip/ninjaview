import SwiftUI

/// Comments for one post, read from tik.ninja's comments panel.
@MainActor
final class CommentsModel: ObservableObject {
    private let engine: ProfileEngine
    private let feed: FeedModel
    let index: Int
    /// The post's comment count as tik.ninja shows it ("35", "1.2K").
    let countLabel: String?
    private let expectedTotal: Int?

    @Published private(set) var comments: [CommentItem] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isLoadingMore = false
    @Published private(set) var note = ""
    @Published private(set) var error: String? = nil
    @Published private(set) var expanded: Set<Int> = []
    @Published private(set) var loadingReplies: Set<Int> = []
    private var exhausted = false
    private var started = false
    /// "1 reply" labels, remembered because tik.ninja swaps them for "Hide replies" once opened.
    private var replyLabels: [Int: String] = [:]

    init(engine: ProfileEngine, feed: FeedModel, index: Int) {
        self.engine = engine
        self.feed = feed
        self.index = index
        let label = feed.details[index]?.stat("comments")
        countLabel = label
        expectedTotal = label.flatMap { CompactNumber.parse($0) }
    }

    func start() async {
        guard !started else { return }
        started = true
        isLoading = true
        error = nil
        do {
            try await feed.ensureOpen(index)
            apply(try await engine.openComments(), previous: nil)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func retry() async {
        started = false
        await start()
    }

    func loadMoreIfNeeded(after comment: CommentItem) async {
        guard comment.index >= comments.count - 3, !exhausted, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let before = comments.count
        do {
            apply(try await engine.moreComments(), previous: before)
        } catch {
            exhausted = true
        }
        isLoadingMore = false
    }

    private func apply(_ snap: CommentsSnapshot, previous: Int?) {
        for comment in snap.comments where !comment.replyLabel.isEmpty {
            replyLabels[comment.index] = comment.replyLabel
        }
        comments = snap.comments
        note = ProfileEngine.tidy(snap.note)
        for comment in snap.comments where comment.repliesOpen && !comment.replies.isEmpty {
            expanded.insert(comment.index)
        }
        let count = snap.comments.count
        if count == 0 {
            exhausted = true
        } else if let previous, count <= previous, !snap.hasMore {
            exhausted = true
        } else if let expectedTotal, loadedCount >= expectedTotal, !snap.hasMore {
            exhausted = true
        }
    }

    private var loadedCount: Int {
        comments.reduce(comments.count) { $0 + $1.replies.count }
    }

    func replyLabel(for comment: CommentItem) -> String? {
        let label = comment.replyLabel.isEmpty ? (replyLabels[comment.index] ?? "") : comment.replyLabel
        if !label.isEmpty { return label }
        if comment.replies.isEmpty { return nil }
        return comment.replies.count == 1 ? "1 reply" : "\(comment.replies.count) replies"
    }

    func toggleReplies(_ comment: CommentItem) async {
        if expanded.contains(comment.index) {
            expanded.remove(comment.index)
            return
        }
        if !comment.replies.isEmpty {
            expanded.insert(comment.index)
            return
        }
        loadingReplies.insert(comment.index)
        defer { loadingReplies.remove(comment.index) }
        do {
            replace(try await engine.replies(comment.index))
            expanded.insert(comment.index)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func moreReplies(_ comment: CommentItem) async {
        loadingReplies.insert(comment.index)
        defer { loadingReplies.remove(comment.index) }
        do {
            replace(try await engine.moreReplies(comment.index))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func replace(_ updated: CommentItem) {
        guard let i = comments.firstIndex(where: { $0.index == updated.index }) else { return }
        comments[i] = updated
    }
}

@MainActor
struct CommentsSheet: View {
    @StateObject private var model: CommentsModel
    private let onOpenProfile: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(engine: ProfileEngine, feed: FeedModel, index: Int, onOpenProfile: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: CommentsModel(engine: engine, feed: feed, index: index))
        self.onOpenProfile = onOpenProfile
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await model.start() }
    }

    private var title: String {
        guard let label = model.countLabel, !label.isEmpty, label != "0" else { return "Comments" }
        return label == "1" ? "1 comment" : "\(label) comments"
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.nvPaper)
        } else if model.comments.isEmpty {
            VStack(spacing: 12) {
                Text(model.error ?? (model.note.isEmpty ? "No comments yet." : model.note))
                    .font(.footnote)
                    .foregroundStyle(Color.nvMuted)
                    .multilineTextAlignment(.center)
                if model.error != nil {
                    Button("Try again") { Task { await model.retry() } }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.nvPaper)
        } else {
            List {
                ForEach(model.comments) { comment in
                    CommentThread(comment: comment, model: model, onOpenProfile: onOpenProfile)
                        .listRowBackground(Color.nvPaper)
                        .listRowSeparatorTint(Color.nvRule)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .onAppear { Task { await model.loadMoreIfNeeded(after: comment) } }
                }
                if model.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.nvPaper)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.nvPaper)
        }
    }
}

@MainActor
struct CommentThread: View {
    let comment: CommentItem
    @ObservedObject var model: CommentsModel
    let onOpenProfile: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommentRow(comment: comment, isReply: false, onOpenProfile: onOpenProfile)
            if let label = model.replyLabel(for: comment) {
                Button {
                    Task { await model.toggleReplies(comment) }
                } label: {
                    HStack(spacing: 6) {
                        Rectangle().fill(Color.nvRule).frame(width: 18, height: 1)
                        Text(model.expanded.contains(comment.index) ? "Hide replies" : "View \(label)")
                            .font(.mono(.caption, weight: .bold))
                            .foregroundStyle(Color.nvSignal)
                        if model.loadingReplies.contains(comment.index) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .padding(.leading, 42)
            }
            if model.expanded.contains(comment.index) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(comment.replies) { reply in
                        CommentRow(comment: reply, isReply: true, onOpenProfile: onOpenProfile)
                    }
                    if comment.repliesMore {
                        Button("View more replies") { Task { await model.moreReplies(comment) } }
                            .buttonStyle(.borderless)
                            .font(.mono(.caption, weight: .bold))
                            .foregroundStyle(Color.nvSignal)
                    }
                }
                .padding(.leading, 42)
            }
        }
    }
}

struct CommentRow: View {
    let comment: CommentItem
    let isReply: Bool
    let onOpenProfile: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(comment.avatarURL, maxPixel: 120)
                .frame(width: isReply ? 26 : 32, height: isReply ? 26 : 32)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button { onOpenProfile(comment.handle) } label: {
                        Text("@\(comment.handle)")
                            .font(.mono(.footnote, weight: .bold))
                            .foregroundStyle(Color.nvInk)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .disabled(comment.handle.isEmpty)
                    .accessibilityHint("Opens this profile")
                    if !comment.time.isEmpty {
                        Text(comment.time)
                            .font(.caption)
                            .foregroundStyle(Color.nvMuted)
                    }
                }
                Text(comment.text)
                    .font(.subheadline)
                    .foregroundStyle(Color.nvInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !comment.likes.isEmpty {
                    Label(comment.likes, systemImage: "heart")
                        .font(.caption)
                        .foregroundStyle(Color.nvMuted)
                        .labelStyle(CompactLabelStyle())
                }
            }
        }
    }
}
