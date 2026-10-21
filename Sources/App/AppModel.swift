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
        case live, archive, posts, instagram, instagramArchive
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
            IGRegistry.shared.prune(keeping: ids)
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
    func open(_ input: String, platform: Platform = .tiktok) -> Bool {
        // instagram.com links always go to Instagram; anything else follows the chosen site,
        // except a tiktok.com link, which always goes to TikTok.
        if IGTarget.isInstagramLink(input) || (platform == .instagram && !input.lowercased().contains("tiktok.com")) {
            guard let handle = IGTarget.parse(input) else {
                DebugLog.shared.add(.nav, "Rejected Instagram input: \(input.prefix(80))")
                return false
            }
            openInstagram(handle)
            return true
        }
        guard let target = TikTokTarget.parse(input) else {
            DebugLog.shared.add(.nav, "Rejected input: \(input.prefix(80))")
            return false
        }
        DebugLog.shared.add(.nav, "Open \(target.query)")
        path.append(Route(query: target.query, handle: target.handle))
        return true
    }

    func popToRoot() { path.removeAll() }

    func openInstagram(_ handle: String) {
        DebugLog.shared.add(.nav, "Open Instagram @\(handle)")
        path.append(Route(query: handle, handle: handle, kind: .instagram))
    }

    func openInstagramArchive(_ handle: String) {
        DebugLog.shared.add(.nav, "Open Instagram archive of @\(handle)")
        path.append(Route(query: handle, handle: handle, kind: .instagramArchive))
    }

    /// Opens a saved or recent row on the site it came from.
    func reopen(_ item: SavedProfile) {
        if item.site == .instagram {
            openInstagram(item.handle)
        } else {
            open("@" + item.handle)
        }
    }

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
        // ninjaview://instagram/<username> or ninjaview://ig?q=<username or link>
        if ["instagram", "ig"].contains(host.lowercased()), let name = fromQuery ?? parts.last {
            open(name, platform: .instagram)
            return
        }
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

    func didLoad(_ profile: ProfileHeader, platform: Platform = .tiktok) {
        let key = platform.key(profile.handle)
        let site: Platform? = platform == .instagram ? .instagram : nil
        if let i = saved.firstIndex(where: { $0.id == key }) {
            saved[i].handle = profile.handle
            if !profile.name.isEmpty { saved[i].name = profile.name }
            persistSaved()
        }
        let keepHistory = AppSettings.shared.keepHistory
        if keepHistory {
            history.removeAll { $0.id == key }
            history.insert(SavedProfile(handle: profile.handle, name: profile.name, date: Date(), platform: site), at: 0)
            if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
            persistHistory()
        }
        if let avatar = profile.avatarURL, keepHistory || isSaved(profile.handle, platform: platform) {
            AvatarStore.shared.refresh(handle: key, from: avatar)
        }
    }

    func isSaved(_ handle: String, platform: Platform = .tiktok) -> Bool {
        let key = platform.key(handle)
        return saved.contains { $0.id == key }
    }

    func toggleSaved(_ profile: ProfileHeader, platform: Platform = .tiktok) {
        let key = platform.key(profile.handle)
        if isSaved(profile.handle, platform: platform) {
            saved.removeAll { $0.id == key }
        } else {
            let site: Platform? = platform == .instagram ? .instagram : nil
            saved.insert(SavedProfile(handle: profile.handle, name: profile.name, date: Date(), platform: site), at: 0)
            if let avatar = profile.avatarURL { AvatarStore.shared.refresh(handle: key, from: avatar, force: true) }
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
