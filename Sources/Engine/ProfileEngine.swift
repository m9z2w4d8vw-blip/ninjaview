import Foundation
import WebKit

/// Runs page operations one at a time; tik.ninja's page is a single UI state machine.
@MainActor
final class SerialRunner {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task { @MainActor in _ = try? await task.value }
        return try await task.value
    }
}

/// One engine per pushed profile screen, created on first use and torn down when
/// its route leaves the navigation stack.
@MainActor
final class EngineRegistry {
    static let shared = EngineRegistry()
    private var engines: [UUID: ProfileEngine] = [:]
    /// Closed engines, kept briefly so a screen still animating away never starts a new page.
    private var retired: [UUID: ProfileEngine] = [:]

    func engine(for route: Route) -> ProfileEngine {
        if let existing = engines[route.id] ?? retired[route.id] { return existing }
        let engine = ProfileEngine(route: route)
        engines[route.id] = engine
        return engine
    }

    func prune(keeping ids: Set<UUID>) {
        for (id, engine) in Array(engines) where !ids.contains(id) {
            engine.teardown()
            engines[id] = nil
            retired[id] = engine
        }
        if retired.count > 24 { retired.removeAll() }
    }
}

struct LookupResult: Decodable {
    let profile: ProfileHeader?
    let item: ItemDetail?
    let status: String
    let error: String
}

struct TabSnapshot: Decodable {
    let tab: String
    let exists: Bool
    let rendered: Bool
    let loading: Bool
    let hasMore: Bool
    let ended: Bool
    let endText: String
    let items: [PostItem]
    let users: [UserCard]
    let message: String
}

struct TabState {
    var items: [PostItem] = []
    var users: [UserCard] = []
    var loaded = false
    var isLoading = false
    var exhausted = false
    var endText = ""
    var message = ""
    var error: String?

    var isEmpty: Bool { items.isEmpty && users.isEmpty }
}

/// Drives one hidden tik.ninja page and publishes everything the native
/// profile screen, post viewer and comments sheet show.
@MainActor
final class ProfileEngine: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(EngineFailure)
    }

    let route: Route
    let bridge: PageBridge

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var header: ProfileHeader? = nil
    @Published private(set) var liveStatus = ""
    @Published private(set) var isSlow = false
    @Published private(set) var selectedTab: ProfileTab = .videos
    @Published private(set) var tabs: [ProfileTab: TabState] = [:]
    @Published private(set) var analytics: [String]? = nil
    @Published private(set) var analyticsLoading = false
    /// The post a pasted post link opened, for the viewer to present.
    @Published private(set) var linkedPost: ItemDetail? = nil
    @Published var pageVisible = false
    @Published var dialog: JSDialog? = nil {
        didSet { if let old = oldValue, old !== dialog { old.complete(false) } }
    }

    private let runner = SerialRunner()
    private var started = false
    private var generation = 0
    private var slowTask: Task<Void, Never>?

    init(route: Route) {
        self.route = route
        bridge = PageBridge(WebFactory.shared.dequeue())
        bridge.delegate = self
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Task { await boot() }
    }

    func reload() async {
        generation += 1
        bridge.reload()
        await boot()
    }

    func teardown() {
        generation += 1
        slowTask?.cancel()
        dialog = nil
        bridge.teardown()
    }

    private func boot() async {
        let gen = generation
        if header == nil { phase = .loading }
        liveStatus = ""
        armSlowTimer()
        guard await bridge.waitUntilReady(timeout: 30) else {
            guard gen == generation else { return }
            if case .failed = phase { return } // the check-page message already explains it
            fail("Couldn't load tik.ninja", "The page didn't finish loading. Check your connection, then try again.")
            return
        }
        guard gen == generation else { return }
        do {
            let query = route.query
            let json = try await runner.run { [bridge] in
                try await bridge.call("return JSON.stringify(await window.__nv.lookup(q));", ["q": query], timeout: 50)
            }
            guard gen == generation else { return }
            let result = try bridge.decode(LookupResult.self, json)
            stopSlowTimer()
            if let profile = result.profile {
                header = profile
                tabs = [:]
                analytics = nil
                phase = .ready
                AppModel.shared.didLoad(profile)
                if let item = result.item { linkedPost = item }
                await load(selectedTab)
            } else if let item = result.item {
                phase = .ready
                linkedPost = item
            } else if result.error == "status" {
                fail("tik.ninja couldn't show this account", result.status)
            } else {
                fail("No profile came back", result.status.isEmpty
                     ? "tik.ninja didn't return this account in time. It may not exist, or the site is busy."
                     : result.status)
            }
        } catch {
            guard gen == generation else { return }
            fail("Lookup failed", error.localizedDescription)
        }
    }

    private func fail(_ title: String, _ detail: String) {
        stopSlowTimer()
        phase = .failed(EngineFailure(title: title, detail: detail))
        DebugLog.shared.add(.web, "\(title): \(detail)")
    }

    private func armSlowTimer() {
        isSlow = false
        slowTask?.cancel()
        slowTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !Task.isCancelled, self.phase == .loading else { return }
            self.isSlow = true
        }
    }

    private func stopSlowTimer() {
        slowTask?.cancel()
        isSlow = false
    }

    // MARK: Tabs

    func select(_ tab: ProfileTab) {
        selectedTab = tab
        if tabs[tab]?.loaded != true { Task { await load(tab) } }
    }

    func load(_ tab: ProfileTab) async {
        guard phase == .ready, header != nil else { return }
        var state = tabs[tab] ?? TabState()
        guard !state.isLoading else { return }
        state.isLoading = true
        state.error = nil
        tabs[tab] = state
        let gen = generation
        let name = tab.rawValue
        do {
            let json = try await runner.run { [bridge] in
                try await bridge.call("return JSON.stringify(await window.__nv.openTab(t));", ["t": name], timeout: 40)
            }
            guard gen == generation else { return }
            apply(try bridge.decode(TabSnapshot.self, json), to: tab, previousCount: nil)
        } catch {
            guard gen == generation else { return }
            tabs[tab]?.isLoading = false
            tabs[tab]?.error = error.localizedDescription
        }
    }

    func loadMore(_ tab: ProfileTab) async {
        guard var state = tabs[tab], state.loaded, !state.isLoading, !state.exhausted else { return }
        let before = state.items.count + state.users.count
        state.isLoading = true
        tabs[tab] = state
        let gen = generation
        let name = tab.rawValue
        do {
            let json = try await runner.run { [bridge] in
                try await bridge.call("return JSON.stringify(await window.__nv.loadMore(t));", ["t": name], timeout: 40)
            }
            guard gen == generation else { return }
            apply(try bridge.decode(TabSnapshot.self, json), to: tab, previousCount: before)
        } catch {
            guard gen == generation else { return }
            tabs[tab]?.isLoading = false
            tabs[tab]?.error = error.localizedDescription
        }
    }

    private func apply(_ snap: TabSnapshot, to tab: ProfileTab, previousCount: Int?) {
        var state = tabs[tab] ?? TabState()
        let count = snap.items.count + snap.users.count
        state.items = snap.items
        state.users = snap.users
        state.isLoading = false
        state.endText = Self.tidy(snap.endText)
        state.message = Self.tidy(snap.message)
        if snap.loading && count == 0 {
            state.loaded = false
            state.error = "tik.ninja is still loading this tab."
        } else {
            state.loaded = true
            state.error = nil
        }
        if let previousCount {
            // Stop paging once the site says it's done or an attempt added nothing.
            state.exhausted = snap.ended || (count <= previousCount && !snap.hasMore)
        } else {
            state.exhausted = snap.ended || (count == 0 && !snap.loading)
        }
        tabs[tab] = state
        DebugLog.shared.add(.web, "\(tab.rawValue): \(count) loaded\(state.exhausted ? ", end" : "")")
    }

    /// "— All videos loaded —" becomes "All videos loaded".
    static func tidy(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2014}\u{2013}- ").union(.whitespacesAndNewlines))
    }

    // MARK: Posts

    func openItem(_ tab: ProfileTab, _ index: Int) async throws -> ItemDetail {
        let name = tab.rawValue
        let json = try await runner.run { [bridge] in
            try await bridge.call("return JSON.stringify(await window.__nv.openItem(t, i));", ["t": name, "i": index], timeout: 45)
        }
        let detail = try bridge.decode(ItemDetail.self, json)
        if !detail.error.isEmpty { throw EngineError.page(detail.error) }
        return detail
    }

    func closeItem() async {
        _ = try? await runner.run { [bridge] in
            try await bridge.call("return JSON.stringify(await window.__nv.closeItem());")
        }
    }

    func requestAudio() async throws {
        let json = try await runner.run { [bridge] in
            try await bridge.call("return JSON.stringify(window.__nv.audio());")
        }
        let reply = try bridge.decode(AudioReply.self, json)
        if !reply.ok { throw EngineError.page("noaudio") }
    }

    // MARK: Comments

    func openComments() async throws -> CommentsSnapshot {
        let json = try await runner.run { [bridge] in
            try await bridge.call("return JSON.stringify(await window.__nv.comments());", timeout: 30)
        }
        let snap = try bridge.decode(CommentsSnapshot.self, json)
        if !snap.error.isEmpty { throw EngineError.page(snap.error) }
        return snap
    }

    func moreComments() async throws -> CommentsSnapshot {
        let json = try await runner.run { [bridge] in
            try await bridge.call("return JSON.stringify(await window.__nv.moreComments());", timeout: 30)
        }
        return try bridge.decode(CommentsSnapshot.self, json)
    }

    func replies(_ index: Int) async throws -> CommentItem {
        let json = try await runner.run { [bridge] in
            try await bridge.call("return JSON.stringify(await window.__nv.replies(i));", ["i": index], timeout: 30)
        }
        guard let comment = try bridge.decode(CommentItem?.self, json) else { throw EngineError.page("missing") }
        return comment
    }

    func moreReplies(_ index: Int) async throws -> CommentItem {
        let json = try await runner.run { [bridge] in
            try await bridge.call("return JSON.stringify(await window.__nv.moreReplies(i));", ["i": index], timeout: 30)
        }
        guard let comment = try bridge.decode(CommentItem?.self, json) else { throw EngineError.page("missing") }
        return comment
    }

    // MARK: Analytics

    func loadAnalytics() async {
        guard analytics == nil, !analyticsLoading, phase == .ready else { return }
        analyticsLoading = true
        defer { analyticsLoading = false }
        do {
            let json = try await runner.run { [bridge] in
                try await bridge.call("return JSON.stringify(await window.__nv.analytics());", timeout: 30)
            }
            analytics = try bridge.decode(AnalyticsSnapshot.self, json).lines
        } catch {
            analytics = []
            DebugLog.shared.add(.web, "Analytics failed: \(error.localizedDescription)")
        }
    }

    // MARK: The page itself (verification checks, debugging)

    func showPage() { pageVisible = true }

    func pageDismissed() {
        bridge.park()
        Task { await resync() }
    }

    /// After the user touched the page, make native state match it again.
    private func resync() async {
        guard phase == .ready, let current = header else {
            await boot()
            return
        }
        let reply = try? await runner.run { [bridge] in
            try await bridge.call("window.__nv.closeOverlays(); return JSON.stringify(window.__nv.profile());")
        }
        let onPage = reply.flatMap { try? JSONDecoder().decode(ProfileHeader?.self, from: Data($0.utf8)) }
        if onPage?.key != current.key {
            await reload()
        } else {
            tabs = [:]
            await load(selectedTab)
        }
    }
}

extension ProfileEngine: PageBridgeDelegate {
    func bridgeDidReceive(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "status":
            if phase == .loading {
                liveStatus = (event["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "noSearchBox":
            if phase == .loading {
                fail("tik.ninja is showing a check page", "Open the page, get past the check, then close it to continue.")
            }
        case "openProfile":
            if let handle = event["handle"] as? String {
                pageVisible = false
                AppModel.shared.open("@" + handle)
            }
        case "download":
            if let s = event["url"] as? String, let url = URL(string: s) {
                let kind = MediaKind(rawValue: event["kind"] as? String ?? "") ?? .unknown
                DownloadCenter.shared.fetch(url, kind: kind, baseName: event["name"] as? String ?? "tiktok")
            }
        default:
            break
        }
    }

    func bridgeLostContent() {
        DebugLog.shared.add(.web, "Page process ended; reloading \(route.query)")
        Task { await reload() }
    }

    func bridgeFailedToLoad(_ error: Error) {
        guard phase == .loading, header == nil else { return }
        fail("Couldn't reach tik.ninja", error.localizedDescription)
    }

    func bridgePresent(_ dialog: JSDialog) {
        self.dialog = dialog
    }
}
