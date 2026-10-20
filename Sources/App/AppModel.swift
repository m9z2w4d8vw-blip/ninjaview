import Foundation

/// One pushed profile screen.
struct Route: Hashable, Identifiable {
    let id = UUID()
    /// Exactly what goes into tik.ninja's search box: a bare handle or a TikTok link.
    let query: String
    /// Known up front when the user typed a handle; nil for short links.
    let handle: String?
    /// A live profile, or an archive read from the phone.
    var kind: Kind = .live

    enum Kind: Hashable {
        case live, archive, posts
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var path: [Route] = [] {
        // Profile screens own off-screen pages and post lists own a player; close the ones no longer on the stack.
        didSet {
            let ids = Set(path.map(\.id))
            EngineRegistry.shared.prune(keeping: ids)
            FeedRegistry.shared.prune(keeping: ids)
        }
    }
    @Published private(set) var saved: [SavedProfile]
    @Published private(set) var history: [SavedProfile]

    private static let savedKey = "savedProfiles"
    private static let historyKey = "history"
    private static let historyLimit = 100

    private init() {
        saved = Store.load([SavedProfile].self, key: Self.savedKey) ?? []
        history = Store.load([SavedProfile].self, key: Self.historyKey) ?? []
    }

    // MARK: Navigation

    @discardableResult
    func open(_ input: String) -> Bool {
        guard let target = TikTokTarget.parse(input) else {
            DebugLog.shared.add(.nav, "Rejected input: \(input.prefix(80))")
            return false
        }
        DebugLog.shared.add(.nav, "Open \(target.query)")
        path.append(Route(query: target.query, handle: target.handle))
        return true
    }

    func popToRoot() { path.removeAll() }

    func openArchive(_ handle: String) {
        DebugLog.shared.add(.nav, "Open archive of @\(handle)")
        path.append(Route(query: handle, handle: handle, kind: .archive))
    }

    /// Pushes a list of posts in the old Instagram style, starting at `index`.
    func openPosts(_ source: FeedSource, index: Int) {
        let feed = FeedModel(source: source, start: index)
        let route = Route(query: "", handle: feed.handle, kind: .posts)
        FeedRegistry.shared.register(feed, for: route.id)
        DebugLog.shared.add(.nav, "Open \(feed.title.lowercased()) of @\(feed.handle) at post \(index + 1)")
        path.append(route)
    }

    /// ninjaview://open?q=<username or link>, ninjaview://@handle, ninjaview://user/<handle>
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "ninjaview",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        DebugLog.shared.add(.nav, "Deep link \(url.absoluteString)")
        let keys = ["q", "url", "u", "user"]
        let fromQuery = components.queryItems?.first(where: { keys.contains($0.name.lowercased()) })?.value
        let parts = components.path.split(separator: "/").map(String.init)
        let host = components.host ?? ""
        var candidate: String?
        if let fromQuery, !fromQuery.isEmpty {
            candidate = fromQuery
        } else if ["open", "user", "profile"].contains(host.lowercased()) {
            candidate = parts.last
        } else if !host.isEmpty {
            candidate = host
        } else {
            candidate = parts.last
        }
        if let candidate { open(candidate) }
    }

    // MARK: Saved and recent profiles (on device only)

    func didLoad(_ profile: ProfileHeader) {
        let key = profile.key
        if let i = saved.firstIndex(where: { $0.id == key }) {
            saved[i].handle = profile.handle
            if !profile.name.isEmpty { saved[i].name = profile.name }
            persistSaved()
        }
        let keepHistory = AppSettings.shared.keepHistory
        if keepHistory {
            history.removeAll { $0.id == key }
            history.insert(SavedProfile(handle: profile.handle, name: profile.name, date: Date()), at: 0)
            if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
            persistHistory()
        }
        if let avatar = profile.avatarURL, keepHistory || isSaved(profile.handle) {
            AvatarStore.shared.refresh(handle: profile.handle, from: avatar)
        }
    }

    func isSaved(_ handle: String) -> Bool {
        saved.contains { $0.id == handle.lowercased() }
    }

    func toggleSaved(_ profile: ProfileHeader) {
        if isSaved(profile.handle) {
            saved.removeAll { $0.id == profile.key }
        } else {
            saved.insert(SavedProfile(handle: profile.handle, name: profile.name, date: Date()), at: 0)
            if let avatar = profile.avatarURL { AvatarStore.shared.refresh(handle: profile.handle, from: avatar, force: true) }
        }
        persistSaved()
    }

    func unsave(_ item: SavedProfile) {
        saved.removeAll { $0.id == item.id }
        persistSaved()
        pruneAvatars()
    }

    func forget(_ item: SavedProfile) {
        history.removeAll { $0.id == item.id }
        persistHistory()
        pruneAvatars()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
        pruneAvatars()
    }

    private func pruneAvatars() {
        AvatarStore.shared.prune(keeping: Set(saved.map(\.id) + history.map(\.id)))
    }

    private func persistSaved() { Store.save(saved, key: Self.savedKey) }
    private func persistHistory() { Store.save(history, key: Self.historyKey) }
}
