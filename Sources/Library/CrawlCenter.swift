import Foundation
import SwiftUI
import UIKit

/// One background download of a profile: a session copy, or an archive that's kept.
@MainActor
final class Crawl: ObservableObject, Identifiable {
    enum Mode: String {
        case session, archive
    }

    enum State: Equatable {
        case queued, running, paused, finished
        case failed(String)
    }

    nonisolated static func id(_ handle: String, _ mode: Mode) -> String { "\(mode.rawValue):\(handle.lowercased())" }

    let handle: String
    let mode: Mode
    let id: String
    @Published fileprivate(set) var state: State = .queued
    @Published fileprivate(set) var activity = ""
    @Published fileprivate(set) var postsDone = 0
    @Published fileprivate(set) var postsTotal = 0
    fileprivate var pauseRequested = false
    fileprivate var deleteWhenStopped = false
    /// When this download started over on a fresh page, for the limit on restarts.
    fileprivate var restarts: [Date] = []

    init(handle: String, mode: Mode) {
        self.handle = handle
        self.mode = mode
        id = Crawl.id(handle, mode)
    }

    var store: ProfileStore { mode == .session ? ProfileStore.session : ProfileStore.archive }
    var isActive: Bool { state == .running || state == .queued }
    var fraction: Double { postsTotal > 0 ? min(1, Double(postsDone) / Double(postsTotal)) : 0 }

    /// Reposts are other people's posts, so archives leave them out.
    var tabs: [ProfileTab] { mode == .session ? [.videos, .reposts, .stories, .highlights] : [.videos, .stories, .highlights] }
    var postCap: Int { mode == .session ? CrawlLimits.sessionPostsPerTab : CrawlLimits.archivePostsPerTab }
}

/// Runs downloads one at a time on their own hidden tik.ninja page, so the profile on
/// screen stays responsive. Archives go first; session copies favour the newest profile.
/// A download steps aside when something more important arrives and picks up later
/// where it stopped, skipping posts it already saved.
@MainActor
final class CrawlCenter: ObservableObject {
    static let shared = CrawlCenter()

    @Published private(set) var crawls: [String: Crawl] = [:]
    private var archiveQueue: [String] = []
    private var sessionQueue: [String] = []
    private var running: Crawl?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let fetcher = MediaFetcher()

    func find(_ handle: String, _ mode: Crawl.Mode) -> Crawl? { crawls[Crawl.id(handle, mode)] }

    /// The download running right now, for reports.
    var current: Crawl? { running }

    /// Download a profile for this session (it's erased when the app closes).
    func prefetch(_ handle: String) {
        guard AppSettings.shared.prefetch else { return }
        let crawl = ensure(handle, .session)
        if crawl.state == .finished { return }
        sessionQueue.removeAll { $0 == crawl.id }
        sessionQueue.insert(crawl.id, at: 0)
        if crawl.state != .running { crawl.state = .queued }
        pump()
    }

    /// Start, resume or update a profile's archive.
    func archive(_ handle: String) {
        let crawl = ensure(handle, .archive)
        crawl.pauseRequested = false
        crawl.deleteWhenStopped = false
        if crawl.state == .running { return }
        crawl.state = .queued
        if !archiveQueue.contains(crawl.id) { archiveQueue.append(crawl.id) }
        pump()
    }

    func pause(_ crawl: Crawl) {
        crawl.pauseRequested = true
        archiveQueue.removeAll { $0 == crawl.id }
        sessionQueue.removeAll { $0 == crawl.id }
        if running !== crawl {
            crawl.state = .paused
            crawl.store.update(crawl.handle, now: true) { $0.status = .paused }
        }
    }

    func deleteArchive(_ handle: String) {
        if let crawl = find(handle, .archive) {
            if crawl === running {
                crawl.deleteWhenStopped = true
                pause(crawl)
                return
            }
            pause(crawl)
            crawls[crawl.id] = nil
        }
        ProfileStore.archive.delete(handle)
    }

    func deleteAllArchives() {
        for handle in ProfileStore.archive.profiles.values.map(\.handle) { deleteArchive(handle) }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Ask iOS for a little extra time to finish the post in progress.
            guard running != nil, backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NinjaView downloads") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
        case .active:
            endBackgroundTask()
        default:
            break
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Scheduling

    private func ensure(_ handle: String, _ mode: Crawl.Mode) -> Crawl {
        let id = Crawl.id(handle, mode)
        if let existing = crawls[id] { return existing }
        let crawl = Crawl(handle: handle, mode: mode)
        crawls[id] = crawl
        return crawl
    }

    private func nextID() -> String? { archiveQueue.first ?? sessionQueue.first }

    private func shouldYield(_ crawl: Crawl) -> Bool {
        if crawl.pauseRequested { return true }
        guard let next = nextID() else { return false }
        return next != crawl.id
    }

    private func pump() {
        guard running == nil, let id = nextID(), let crawl = crawls[id] else { return }
        running = crawl
        Task { [weak self] in
            guard let self else { return }
            await self.run(crawl)
            self.running = nil
            if crawl.state != .queued {
                self.archiveQueue.removeAll { $0 == id }
                self.sessionQueue.removeAll { $0 == id }
            }
            if crawl.deleteWhenStopped {
                crawl.deleteWhenStopped = false
                self.crawls[crawl.id] = nil
                ProfileStore.archive.delete(crawl.handle)
            }
            self.pump()
        }
    }

    // MARK: The download itself

    private func run(_ crawl: Crawl) async {
        let store = crawl.store
        crawl.state = .running
        crawl.pauseRequested = false
        crawl.postsDone = 0
        crawl.postsTotal = 0
        crawl.activity = "Looking up @\(crawl.handle)"
        store.begin(crawl.handle)

        let engine = ProfileEngine(route: Route(query: crawl.handle, handle: crawl.handle), headless: true,
                                   purpose: crawl.mode == .archive ? "archive" : "session copy")
        defer { engine.teardown() }
        DebugLog.shared.add(.crawl, "Started \(crawl.mode.rawValue) download of @\(crawl.handle) on hidden page \(engine.bridge.tag)")
        engine.start()
        while engine.phase == .loading {
            if shouldYield(crawl) {
                stop(crawl, store)
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard engine.phase == .ready, let header = engine.header else {
            var reason = "tik.ninja didn't return this account."
            if case .failed(let failure) = engine.phase { reason = failure.detail.isEmpty ? failure.title : failure.detail }
            crawl.state = .failed(reason)
            crawl.activity = ""
            store.update(crawl.handle, now: true) { profile in
                profile.status = .failed
                profile.note = reason
            }
            DebugLog.shared.error(.crawl, "Download of @\(crawl.handle) failed: \(reason)")
            return
        }

        store.update(crawl.handle) { $0.header = header }
        if let avatar = header.avatarURL, let file = await fetcher.save(avatar, into: store.folder(crawl.handle), name: "avatar") {
            store.update(crawl.handle) { $0.avatarFile = file }
        }
        await engine.loadAnalytics()
        if let lines = engine.analytics, !lines.isEmpty {
            store.update(crawl.handle) { $0.analytics = lines }
        }

        // Lists tik.ninja kept refusing: the download then stops short of complete, so it can be resumed.
        var incomplete: [String] = []
        for tab in crawl.tabs {
            if shouldYield(crawl) {
                stop(crawl, store)
                return
            }
            if engine.needsFreshPage {
                await restart(crawl, store, engine)
                return
            }
            crawl.activity = "Reading \(tab.title.lowercased())"
            let page = await pageThrough(tab, engine: engine, crawl: crawl, cap: crawl.postCap)
            if engine.needsFreshPage {
                await restart(crawl, store, engine)
                return
            }
            if !page.complete { incomplete.append(tab.title.lowercased()) }
            let items = page.items
            let keys = StableKey.keys(for: items, tab: tab)
            store.setEntries(crawl.handle, tab, items: items, keys: keys)
            crawl.postsTotal += items.count
            for (item, key) in zip(items, keys) {
                if shouldYield(crawl) {
                    stop(crawl, store)
                    return
                }
                if engine.needsFreshPage {
                    await restart(crawl, store, engine)
                    return
                }
                let alreadySaved = store.isComplete(crawl.handle, tab, key)
                    || (crawl.mode == .session && ProfileStore.archive.isComplete(crawl.handle, tab, key))
                if !alreadySaved {
                    crawl.activity = "Saving \(tab.title.lowercased()) \(item.index + 1) of \(items.count)"
                    await savePost(item, key: key, tab: tab, crawl: crawl, engine: engine)
                    try? await Task.sleep(nanoseconds: CrawlLimits.pause)
                } else if crawl.mode == .archive, AppSettings.shared.saveComments,
                          let stored = store.loadPost(crawl.handle, tab, key), stored.needsReplies {
                    // Saved before, but some reply threads didn't load then: get just those now.
                    crawl.activity = "Saving replies for \(tab.title.lowercased()) \(item.index + 1) of \(items.count)"
                    await refreshReplies(stored, item: item, tab: tab, crawl: crawl, engine: engine)
                    try? await Task.sleep(nanoseconds: CrawlLimits.pause)
                }
                crawl.postsDone += 1
            }
        }
        await engine.closeItem()

        if AppSettings.shared.saveLists {
            for tab in [ProfileTab.followers, .following] {
                if shouldYield(crawl) {
                    stop(crawl, store)
                    return
                }
                if engine.needsFreshPage {
                    await restart(crawl, store, engine)
                    return
                }
                crawl.activity = "Reading \(tab.title.lowercased())"
                let page = await pageThrough(tab, engine: engine, crawl: crawl, cap: CrawlLimits.usersPerList)
                if engine.needsFreshPage {
                    await restart(crawl, store, engine)
                    return
                }
                let users = engine.tabs[tab]?.users ?? []
                // A list cut short by a refusal only replaces a saved one that's shorter.
                if page.complete || users.count > store.loadUsers(crawl.handle, tab).count {
                    store.saveUsers(users, tab: tab, handle: crawl.handle)
                }
                if !page.complete {
                    incomplete.append(tab.title.lowercased())
                    DebugLog.shared.warn(.crawl, "[\(engine.bridge.label)] tik.ninja refused the \(tab.rawValue) list of @\(crawl.handle) partway (\(users.count) loaded); the longer of it and the saved list is kept")
                }
            }
        }

        if !incomplete.isEmpty {
            let reason = "tik.ninja refused the \(incomplete.joined(separator: " and ")) \(incomplete.count == 1 ? "list" : "lists") partway; resume to finish"
            let size = ProfileStore.size(of: store.folder(crawl.handle))
            crawl.activity = ""
            crawl.state = .failed(reason)
            store.update(crawl.handle, now: true) { profile in
                profile.status = .failed
                profile.note = reason
                profile.bytes = size
            }
            DebugLog.shared.warn(.crawl, "Stopped the \(crawl.mode.rawValue) download of @\(crawl.handle) short of complete: \(reason)")
            return
        }
        store.finish(crawl.handle)
        crawl.activity = ""
        crawl.state = .finished
        DebugLog.shared.add(.crawl, "Finished \(crawl.mode.rawValue) download of @\(crawl.handle): \(crawl.postsDone) posts")
    }

    private func stop(_ crawl: Crawl, _ store: ProfileStore) {
        crawl.activity = ""
        DebugLog.shared.add(.crawl, crawl.pauseRequested
            ? "Paused the \(crawl.mode.rawValue) download of @\(crawl.handle) after \(crawl.postsDone) of \(crawl.postsTotal) posts"
            : "The \(crawl.mode.rawValue) download of @\(crawl.handle) stepped aside for another one after \(crawl.postsDone) of \(crawl.postsTotal) posts")
        if crawl.pauseRequested {
            crawl.state = .paused
            let size = ProfileStore.size(of: store.folder(crawl.handle))
            store.update(crawl.handle, now: true) { profile in
                profile.status = .paused
                profile.bytes = size
            }
        } else {
            crawl.state = .queued // stepped aside for something newer; resumes later
        }
    }

    /// Opens a tab and keeps loading more until the end (or the cap). A list tik.ninja refuses is
    /// retried after its Retry-After instead of being taken as finished.
    private func pageThrough(_ tab: ProfileTab, engine: ProfileEngine, crawl: Crawl, cap: Int) async -> PageResult {
        await engine.load(tab)
        await settle(engine, tab)
        if engine.tabs[tab]?.loaded != true && engine.tabs[tab]?.refusal == nil {
            await engine.load(tab)
            await settle(engine, tab)
        }
        var stalls = 0
        var refusals = 0
        while !engine.needsFreshPage, let state = engine.tabs[tab] {
            if let refusal = state.refusal {
                // A 429 is waited out, up to three times in a row; anything else ends the list here.
                guard refusal == "limited", refusals < 3 else { break }
                refusals += 1
                await waitOut(state.retryAfter, engine: engine, what: "the \(tab.rawValue) list")
                if state.loaded {
                    await engine.loadMore(tab)
                } else {
                    await engine.load(tab)
                }
                await settle(engine, tab)
                continue
            }
            refusals = 0
            guard state.loaded, !state.exhausted, stalls < 3 else { break }
            let count = state.items.count + state.users.count
            if count >= cap || shouldYield(crawl) { break }
            await engine.loadMore(tab)
            await settle(engine, tab)
            let after = (engine.tabs[tab]?.items.count ?? 0) + (engine.tabs[tab]?.users.count ?? 0)
            stalls = after > count ? 0 : stalls + 1
        }
        let final = engine.tabs[tab]
        return PageResult(items: Array((final?.items ?? []).prefix(cap)),
                          complete: final?.refusal == nil && final?.loaded == true)
    }

    private struct PageResult {
        let items: [PostItem]
        /// False when tik.ninja refused the list partway and waiting didn't help.
        let complete: Bool
    }

    /// tik.ninja refused this page's session, or it went long enough without an answer that it
    /// would: start the download over on a fresh page, which skips everything already saved. A
    /// fourth restart within 15 minutes stops it instead, so a site refusing every new session
    /// can't keep it looping.
    private func restart(_ crawl: Crawl, _ store: ProfileStore, _ engine: ProfileEngine) async {
        let now = Date()
        crawl.restarts = crawl.restarts.filter { now.timeIntervalSince($0) < 15 * 60 } + [now]
        crawl.activity = ""
        let why = engine.sessionRefusedAt != nil
            ? "tik.ninja refused its session (HTTP 403)"
            : "its session went \(PageBridge.ago(now.addingTimeInterval(-engine.sessionIdle))) without an answer"
        guard crawl.restarts.count <= 3 else {
            let reason = "tik.ninja kept refusing new sessions; try again later"
            crawl.state = .failed(reason)
            store.update(crawl.handle, now: true) { profile in
                profile.status = .failed
                profile.note = reason
            }
            DebugLog.shared.error(.crawl, "[\(engine.bridge.label)] Gave up the \(crawl.mode.rawValue) download of @\(crawl.handle): \(why), the fourth time in 15 minutes")
            return
        }
        DebugLog.shared.warn(.crawl, "[\(engine.bridge.label)] \(why); restarting the \(crawl.mode.rawValue) download of @\(crawl.handle) on a fresh page (it skips what's saved)")
        crawl.state = .queued
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    /// Waits out tik.ninja's Retry-After: at least the 10 seconds it usually asks for, at most a minute.
    private func waitOut(_ seconds: Int, engine: ProfileEngine, what: String) async {
        let wait = min(60, max(10, seconds))
        DebugLog.shared.warn(.crawl, "[\(engine.bridge.label)] tik.ninja refused \(what) (HTTP 429); waiting \(wait) s before trying again")
        try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
    }

    /// Opens a post, waiting out one refusal (429) rather than skipping the post.
    private func openPatiently(_ engine: ProfileEngine, _ tab: ProfileTab, _ index: Int) async throws -> ItemDetail {
        do {
            return try await engine.openItem(tab, index)
        } catch EngineError.limited(let seconds) {
            await waitOut(seconds, engine: engine, what: "opening a post")
            return try await engine.openItem(tab, index)
        }
    }

    /// Waits out a tab load that's already in flight (the engine's own first load, say).
    private func settle(_ engine: ProfileEngine, _ tab: ProfileTab) async {
        var waited = 0
        while engine.tabs[tab]?.isLoading == true && waited < 600 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
    }

    private func savePost(_ item: PostItem, key: String, tab: ProfileTab, crawl: Crawl, engine: ProfileEngine) async {
        let store = crawl.store
        let folder = store.postFolder(crawl.handle, tab, key)
        let started = Date()
        // An archive reuses whatever this session already downloaded.
        if crawl.mode == .archive, let cached = ProfileStore.session.loadPost(crawl.handle, tab, key), cached.detail != nil,
           Self.copyFiles(of: cached, from: ProfileStore.session.postFolder(crawl.handle, tab, key), to: folder) {
            store.savePost(cached, handle: crawl.handle, complete: true)
            // The temporary copy opens fewer reply threads; fill in the rest for the archive.
            if AppSettings.shared.saveComments && cached.unopenedThreads > 0 {
                await refreshReplies(cached, item: item, tab: tab, crawl: crawl, engine: engine)
            }
            return
        }
        var post = StoredPost(key: key, tab: tab.rawValue, item: item, detail: nil, thumbFile: nil, videoFile: nil,
                              photoFiles: [], comments: [], commentsNote: "", savedAt: Date())
        if let thumb = item.thumbURL {
            post.thumbFile = await fetcher.save(thumb, into: folder, name: "cover")
        }
        do {
            let detail = try await openPatiently(engine, tab, item.index)
            post.detail = detail
            if detail.isVideo, let url = detail.videoURL {
                post.videoFile = await fetcher.save(url, into: folder, name: "video")
            }
            for (offset, url) in detail.photoURLs.enumerated() {
                if let file = await fetcher.save(url, into: folder, name: "photo-\(offset + 1)") {
                    post.photoFiles.append(file)
                }
            }
            if detail.hasComments && AppSettings.shared.saveComments {
                let limit = crawl.mode == .archive ? CrawlLimits.threadsPerPost : CrawlLimits.sessionThreadsPerPost
                let saved = await collectComments(engine, threadLimit: limit)
                post.comments = saved.comments
                post.commentsNote = saved.note
                post.repliesMissing = saved.missingThreads
            }
            let videoOK = !detail.isVideo || post.videoFile != nil
            let photosOK = post.photoFiles.count == detail.photoURLs.count
            store.savePost(post, handle: crawl.handle, complete: videoOK && photosOK)
            let missing = post.repliesMissing ?? 0
            let leftOver = missing > 0 ? ", \(missing) reply threads left for the next update" : ""
            let media = "\(post.videoFile != nil ? "video" : "no video"), \(post.photoFiles.count) photos, \(post.comments.count) comments, \(post.replyCount) replies\(leftOver)"
            DebugLog.shared.add(.crawl, "Saved \(tab.rawValue) \(item.index + 1) of @\(crawl.handle) in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(media)\(videoOK && photosOK ? "" : ", some media missing")",
                                level: videoOK && photosOK ? .info : .warning)
        } catch {
            DebugLog.shared.warn(.crawl, "Skipped \(tab.rawValue) \(item.index + 1) of @\(crawl.handle): \(error.localizedDescription)")
        }
    }

    private struct SavedComments {
        let comments: [CommentItem]
        let note: String
        /// Threads that said they had replies but wouldn't open (almost always tik.ninja's rate limit).
        let missingThreads: Int
    }

    /// Every comment the page will load (up to the cap), with reply threads opened one at a time.
    /// A refusal (429) is waited out for as long as tik.ninja's Retry-After asks; after three refused
    /// threads in a row it stops opening threads for this post and counts the rest as missing, so the
    /// next archive update fills them in. A refused session (403) stops it at once, so the download
    /// can start over on a fresh page.
    private func collectComments(_ engine: ProfileEngine, threadLimit: Int) async -> SavedComments {
        var firstSnap: CommentsSnapshot? = nil
        for attempt in 0..<2 {
            do {
                firstSnap = try await engine.openComments()
                break
            } catch EngineError.limited(let seconds) where attempt == 0 {
                await waitOut(seconds, engine: engine, what: "the comments")
                await engine.closeComments()
            } catch {
                break
            }
        }
        guard let first = firstSnap else {
            return SavedComments(comments: [], note: "", missingThreads: 0)
        }
        var snap = first
        var limitedRounds = 0
        while snap.comments.count < CrawlLimits.commentsPerPost && !engine.needsFreshPage {
            do {
                let next = try await engine.moreComments()
                let grew = next.comments.count > snap.comments.count
                snap = next
                if !grew { break }
                limitedRounds = 0
            } catch EngineError.limited(let seconds) {
                limitedRounds += 1
                if limitedRounds > 2 { break }
                await waitOut(seconds, engine: engine, what: "more comments")
            } catch {
                break
            }
        }
        var threads: [Int: CommentItem] = [:]
        var refusals = 0
        var missing = 0
        for comment in snap.comments.filter({ !$0.replyLabel.isEmpty }).prefix(threadLimit) {
            if Task.isCancelled || refusals >= 3 || engine.needsFreshPage {
                missing += 1
                continue
            }
            var thread: CommentItem? = nil
            do {
                thread = try await openThread(engine, comment.index)
            } catch EngineError.limited(let seconds) {
                refusals += 1
                await waitOut(seconds, engine: engine, what: "a reply thread")
                thread = try? await openThread(engine, comment.index)
            } catch {
                thread = nil
            }
            guard var opened = thread else {
                missing += 1
                continue
            }
            refusals = 0
            var rounds = 0
            while opened.repliesMore && rounds < CrawlLimits.replyRounds && !engine.needsFreshPage {
                try? await Task.sleep(nanoseconds: CrawlLimits.replyPause)
                guard let more = try? await engine.moreReplies(comment.index), more.replies.count > opened.replies.count else { break }
                opened = more
                rounds += 1
            }
            threads[comment.index] = opened
            try? await Task.sleep(nanoseconds: CrawlLimits.replyPause)
        }
        // The page's final state with the threads opened above put back in: the page may have folded
        // some up again, and if that last read fails, what was already collected is kept.
        var base = snap
        if let latest = try? await engine.commentsState(), !latest.comments.isEmpty { base = latest }
        let comments = base.comments.map { comment -> CommentItem in
            guard let thread = threads[comment.index], thread.replies.count > comment.replies.count else { return comment }
            return thread
        }
        await engine.closeComments()
        if missing > 0 {
            DebugLog.shared.warn(.crawl, "[\(engine.bridge.label)] \(missing) reply threads didn't load; the next archive update tries them again")
        }
        return SavedComments(comments: comments, note: ProfileEngine.tidy(base.note), missingThreads: missing)
    }

    /// One reply thread, or nil when it opened empty. A refusal arrives as an error (EngineError.limited and the like).
    private func openThread(_ engine: ProfileEngine, _ index: Int) async throws -> CommentItem? {
        let thread = try await engine.replies(index)
        return thread.replies.isEmpty ? nil : thread
    }

    /// An archived post whose reply threads didn't all load: open it again just for its comments,
    /// and keep everything else as it was saved.
    private func refreshReplies(_ stored: StoredPost, item: PostItem, tab: ProfileTab, crawl: Crawl, engine: ProfileEngine) async {
        let started = Date()
        do {
            let detail = try await openPatiently(engine, tab, item.index)
            var post = stored
            guard detail.hasComments else {
                post.repliesMissing = 0
                crawl.store.savePost(post, handle: crawl.handle, complete: true)
                return
            }
            let saved = await collectComments(engine, threadLimit: CrawlLimits.threadsPerPost)
            post.comments = Self.mergeComments(stored.comments, saved.comments)
            if !saved.note.isEmpty { post.commentsNote = saved.note }
            post.repliesMissing = saved.missingThreads
            crawl.store.savePost(post, handle: crawl.handle, complete: true)
            let still = saved.missingThreads > 0 ? ", \(saved.missingThreads) threads still missing" : ""
            DebugLog.shared.add(.crawl, "Filled in replies for \(tab.rawValue) \(item.index + 1) of @\(crawl.handle) in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(stored.replyCount) to \(post.replyCount) replies\(still)")
        } catch {
            DebugLog.shared.warn(.crawl, "Couldn't reopen \(tab.rawValue) \(item.index + 1) of @\(crawl.handle) for its replies: \(error.localizedDescription)")
        }
    }

    /// Two loads of the same post's comments: keep the longer list, and for each comment whichever
    /// copy has more replies, so a thread refused this time never erases replies saved before.
    nonisolated static func mergeComments(_ old: [CommentItem], _ new: [CommentItem]) -> [CommentItem] {
        func key(_ comment: CommentItem) -> String { comment.handle + "\u{1F}" + comment.text }
        let base = new.count >= old.count ? new : old
        let other = new.count >= old.count ? old : new
        var best: [String: CommentItem] = [:]
        for comment in other where !comment.replies.isEmpty { best[key(comment)] = comment }
        return base.map { comment in
            guard let alt = best[key(comment)], alt.replies.count > comment.replies.count else { return comment }
            return CommentItem(index: comment.index, handle: comment.handle, text: comment.text, avatar: comment.avatar,
                               likes: comment.likes, time: comment.time, replyLabel: alt.replyLabel,
                               repliesOpen: alt.repliesOpen, repliesMore: alt.repliesMore, replies: alt.replies)
        }
    }

    nonisolated private static func copyFiles(of post: StoredPost, from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in [post.thumbFile, post.videoFile].compactMap({ $0 }) + post.photoFiles {
                let target = destination.appendingPathComponent(name)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: source.appendingPathComponent(name), to: target)
            }
            return true
        } catch {
            return false
        }
    }
}

/// Downloads one media file for the store, naming it by what its bytes turn out to be.
@MainActor
final class MediaFetcher {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    /// Saves `url` into `folder` as `name.<ext>`; returns the file name, or nil if it failed.
    func save(_ url: URL, into folder: URL, name: String) async -> String? {
        var began = Date()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var request = URLRequest(url: url)
            if url.scheme?.lowercased().hasPrefix("http") == true {
                request.setValue(WebFactory.userAgent, forHTTPHeaderField: "User-Agent")
                if let referer = LinkRules.referer(for: url) { request.setValue(referer, forHTTPHeaderField: "Referer") }
                if LinkRules.isTikNinja(url), let cookie = await CookieBridge.header(for: url) {
                    request.setValue(cookie, forHTTPHeaderField: "Cookie")
                }
            }
            began = Date()
            let (temp, response) = try await session.download(for: request)
            let http = response as? HTTPURLResponse
            var problem: String? = nil
            if let http, !(200..<300).contains(http.statusCode) {
                var line = "Couldn't save \(name) from \(url.host ?? "a file"): it answered \(HTTPDebug.describe(http))"
                if HTTPDebug.isTextual(http) {
                    let body = HTTPDebug.snippet(file: temp, limit: 400)
                    if !body.isEmpty { line += "\n  body: " + body }
                }
                problem = line
            }
            NetLedger.shared.record(source: "app media saves", kind: "native", method: "GET", url: url, status: http?.statusCode,
                                    ms: PageBridge.ms(since: began), retryAfter: HTTPDebug.retryAfter(response), detail: problem)
            if let problem {
                DebugLog.shared.warn(.crawl, problem)
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
            var ext = MediaSniffer.sniff(temp)?.ext ?? MediaSniffer.ext(forMIME: response.mimeType)
            if ext == nil, !url.pathExtension.isEmpty { ext = url.pathExtension.lowercased() }
            let fileName = "\(name).\(ext ?? "bin")"
            let destination = folder.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            return fileName
        } catch {
            if error is URLError {
                NetLedger.shared.record(source: "app media saves", kind: "native", method: "GET", url: url, status: 0,
                                        ms: PageBridge.ms(since: began))
            }
            DebugLog.shared.warn(.crawl, "Couldn't save \(name) from \(url.host ?? "a file"): \(error.localizedDescription)")
            return nil
        }
    }
}

enum ArchiveExporter {
    /// Zips a folder with the system's built-in "for uploading" file coordination.
    static func zip(_ folder: URL, name: String) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            var result: URL?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipped in
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
                try? FileManager.default.removeItem(at: destination)
                if (try? FileManager.default.copyItem(at: zipped, to: destination)) != nil { result = destination }
            }
            return result
        }.value
    }
}
