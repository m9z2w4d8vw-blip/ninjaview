import Foundation

/// Archives an Instagram account's full post history with a signed-in session: walks the whole
/// grid, then opens each post for its media and complete comment threads, saving everything into
/// the same IGArchive the anonymous path uses. Stories are never touched here.
///
/// Runs only while the app is open. Instagram may rate-limit a long run; this saves as it goes and
/// resumes on the next run, skipping posts already saved (and filling in any that still need
/// comments). It merges with whatever stories were saved anonymously for the same account.
@MainActor
final class IGPostArchiver: ObservableObject {
    static let shared = IGPostArchiver()

    @Published private(set) var activeHandle: String?
    @Published private(set) var status = ""
    @Published private(set) var done = 0
    @Published private(set) var total = 0

    private var session: IGSession?
    private var cancelled = false

    var isRunning: Bool { activeHandle != nil }

    func isRunning(_ handle: String) -> Bool { activeHandle?.lowercased() == handle.lowercased() }

    func cancel() {
        cancelled = true
        status = "Finishing the current post, then stopping"
    }

    /// The session that reads Instagram. Shared so the captcha sheet can show its page.
    func sharedSession() -> IGSession {
        if let session { return session }
        let created = IGSession()
        session = created
        return created
    }

    /// Archives every post of `handle`. Returns a short sentence for a toast.
    func run(_ handle: String) async -> String {
        guard !isRunning else { return "Already archiving @\(activeHandle ?? handle)." }
        guard IGCredentials.shared.isSignedIn else { return "Add your Instagram sign-in in Settings first." }
        cancelled = false
        activeHandle = handle
        status = "Signing in"
        done = 0
        total = 0
        defer {
            activeHandle = nil
            status = ""
            session?.teardown()
            session = nil
        }

        let session = sharedSession()
        guard await session.ensureSignedIn() else {
            return signInProblem(session)
        }

        status = "Finding posts"
        guard let grid = await session.readGrid(handle) else {
            return "Couldn't read @\(handle)'s posts. Try again in a little while."
        }
        // Skip posts already saved that don't still need comments; keep the newest first.
        let existing = IGArchive.shared.account(handle)
        let savedByCode = Dictionary((existing?.posts ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let wanted = grid.items.filter { gridItem in
            guard let old = savedByCode[gridItem.code] else { return true }
            // New comments on a previously complete post also require a refresh.
            return !commentsSettledFor(old) || (gridItem.comments ?? 0) > old.comments.count
        }
        total = wanted.count

        if wanted.isEmpty {
            IGArchive.shared.markSignedIn(handle, profileCount: grid.total, bio: existing?.bio ?? "", stats: existing?.stats ?? [])
            return grid.total > 0 && (existing?.posts.count ?? 0) >= grid.total
                ? "@\(handle) is fully archived (\(grid.total) posts)."
                : "@\(handle)'s posts are up to date."
        }

        var saved = 0, failed = 0
        for (index, item) in wanted.enumerated() {
            if cancelled || Task.isCancelled { break }
            done = index
            status = "Saving post \(index + 1) of \(wanted.count)"
            guard var detail = await session.readPost(item.code, expectedComments: item.comments ?? 0) else {
                failed += 1
                if await sessionBlocked(session) { break }
                continue
            }
            // The grid already has every slide from Instagram's data when the page showed none.
            if detail.media.isEmpty, !item.slides.isEmpty {
                detail = IGPostDetail(code: detail.code, author: detail.author, caption: detail.caption.isEmpty ? (item.caption ?? "") : detail.caption,
                                      date: detail.date, likes: detail.likes, media: item.slides, mediaFrom: "grid",
                                      comments: detail.comments, expandRounds: detail.expandRounds,
                                      expectedComments: detail.expectedComments, commentsComplete: detail.commentsComplete,
                                      commentsNote: detail.commentsNote)
            }
            let ok = await IGArchive.shared.absorbSignedInPost(handle, grid: item, detail: detail, profileTotal: grid.total)
            if ok { saved += 1 } else { failed += 1 }
            done = index + 1
            // A short pause between posts, like the reply pacing, to stay under Instagram's limits.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        IGArchive.shared.markSignedIn(handle, profileCount: grid.total, bio: existing?.bio ?? "", stats: existing?.stats ?? [])
        if cancelled { return "Stopped. Saved \(saved) new post\(saved == 1 ? "" : "s") from @\(handle); run again to continue." }
        var summary = "Saved \(saved) post\(saved == 1 ? "" : "s") from @\(handle)"
        if failed > 0 { summary += ", \(failed) couldn't be saved (run again to retry)" }
        if !grid.ended { summary += ". Instagram didn't list them all; run again later for the rest" }
        return summary + "."
    }

    /// Never mark a partial thread archive as done merely because it contains a comment.
    /// Old archives have no completion marker and are deliberately revisited on update.
    private func commentsSettledFor(_ item: IGArchive.Item) -> Bool {
        item.commentsComplete && (item.expectedComments == 0 || item.comments.count >= item.expectedComments)
    }

    private func sessionBlocked(_ session: IGSession) async -> Bool {
        if case .challenge = session.phase {
            status = "Instagram wants a check"
            return true
        }
        return false
    }

    private func signInProblem(_ session: IGSession) -> String {
        switch session.phase {
        case .challenge: return "Instagram wants to confirm it's you. Open Settings > Instagram and tap Open Instagram to finish, then try again."
        case .loginFailed(let why): return why
        case .failed(let why): return why
        default: return "Couldn't sign in to Instagram."
        }
    }
}
