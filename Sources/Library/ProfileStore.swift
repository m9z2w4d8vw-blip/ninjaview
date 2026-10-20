import Foundation

/// Downloaded profiles on disk.
/// - `session` lives in the temporary folder and is erased at every launch and when the app quits.
/// - `archive` lives in Documents/Archives, survives restarts and shows up in the Files app.
///
/// Layout: `<handle>/profile.json`, `avatar.jpg`, `followers.json`, `following.json`,
/// and `<tab>/<post key>/post.json` beside that post's cover, video or photos.
@MainActor
final class ProfileStore: ObservableObject {
    enum Kind { case session, archive }

    static let session = ProfileStore(.session)
    static let archive = ProfileStore(.archive)

    let kind: Kind
    let root: URL
    @Published private(set) var profiles: [String: StoredProfile] = [:]

    private var postCache: [String: StoredPost] = [:]
    private var saveTasks: [String: Task<Void, Never>] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init(_ kind: Kind) {
        self.kind = kind
        let fm = FileManager.default
        switch kind {
        case .session:
            root = fm.temporaryDirectory.appendingPathComponent("SessionCache", isDirectory: true)
        case .archive:
            root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Archives", isDirectory: true)
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        if kind == .session { try? fm.removeItem(at: root) }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        if kind == .archive { loadAll() }
    }

    // MARK: Paths

    func folder(_ handle: String) -> URL {
        root.appendingPathComponent(handle.lowercased(), isDirectory: true)
    }

    func postFolder(_ handle: String, _ tab: ProfileTab, _ key: String) -> URL {
        folder(handle).appendingPathComponent(tab.rawValue, isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    func avatarURL(_ handle: String) -> URL? {
        guard let file = profile(handle)?.avatarFile else { return nil }
        return folder(handle).appendingPathComponent(file)
    }

    // MARK: Reading

    func profile(_ handle: String) -> StoredProfile? { profiles[handle.lowercased()] }

    var totalBytes: Int64 { profiles.values.reduce(0) { $0 + $1.bytes } }

    func isComplete(_ handle: String, _ tab: ProfileTab, _ key: String) -> Bool {
        profile(handle)?.entries(tab).first(where: { $0.key == key })?.complete == true
    }

    func loadPost(_ handle: String, _ tab: ProfileTab, _ key: String) -> StoredPost? {
        let cacheKey = Self.cacheKey(handle, tab, key)
        if let hit = postCache[cacheKey] { return hit }
        let url = postFolder(handle, tab, key).appendingPathComponent("post.json")
        guard let data = try? Data(contentsOf: url), let post = try? decoder.decode(StoredPost.self, from: data) else { return nil }
        remember(post, cacheKey)
        return post
    }

    func loadUsers(_ handle: String, _ tab: ProfileTab) -> [UserCard] {
        let url = folder(handle).appendingPathComponent("\(tab.rawValue).json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([UserCard].self, from: data)) ?? []
    }

    // MARK: Writing

    @discardableResult
    func begin(_ handle: String) -> StoredProfile {
        let key = handle.lowercased()
        if var existing = profiles[key] {
            existing.status = .working
            existing.note = ""
            profiles[key] = existing
            persist(key, now: true)
            return existing
        }
        let now = Date()
        let fresh = StoredProfile(handle: handle, header: nil, avatarFile: nil, analytics: [], tabs: [:], userCounts: [:],
                                  status: .working, note: "", createdAt: now, updatedAt: now, bytes: 0)
        profiles[key] = fresh
        try? FileManager.default.createDirectory(at: folder(handle), withIntermediateDirectories: true)
        persist(key, now: true)
        return fresh
    }

    func update(_ handle: String, now: Bool = false, _ change: (inout StoredProfile) -> Void) {
        let key = handle.lowercased()
        guard var profile = profiles[key] else { return }
        change(&profile)
        profile.updatedAt = Date()
        profiles[key] = profile
        persist(key, now: now)
    }

    /// Records a tab's posts in the profile's current order. Posts that have since left the
    /// profile stay at the end, so an archive keeps what was deleted.
    func setEntries(_ handle: String, _ tab: ProfileTab, items: [PostItem], keys: [String]) {
        update(handle) { profile in
            let old = profile.tabs[tab.rawValue] ?? []
            var byKey: [String: StoredEntry] = [:]
            for entry in old { byKey[entry.key] = entry }
            var merged: [StoredEntry] = []
            var seen = Set<String>()
            for (item, key) in zip(items, keys) {
                var entry = byKey[key] ?? StoredEntry(key: key, item: item, thumbFile: nil, complete: false)
                entry.item = item
                merged.append(entry)
                seen.insert(key)
            }
            for entry in old where !seen.contains(entry.key) { merged.append(entry) }
            profile.tabs[tab.rawValue] = merged
        }
    }

    /// Saves a post. `complete` is false when some of its media failed, so the next run retries it.
    func savePost(_ post: StoredPost, handle: String, complete: Bool) {
        guard let tab = ProfileTab(rawValue: post.tab) else { return }
        let folder = postFolder(handle, tab, post.key)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? encoder.encode(post) {
            try? data.write(to: folder.appendingPathComponent("post.json"), options: .atomic)
        }
        remember(post, Self.cacheKey(handle, tab, post.key))
        update(handle) { profile in
            var entries = profile.tabs[post.tab] ?? []
            if let i = entries.firstIndex(where: { $0.key == post.key }) {
                entries[i].complete = complete
                entries[i].thumbFile = post.thumbFile
            } else {
                entries.append(StoredEntry(key: post.key, item: post.item, thumbFile: post.thumbFile, complete: complete))
            }
            profile.tabs[post.tab] = entries
        }
    }

    func saveUsers(_ users: [UserCard], tab: ProfileTab, handle: String) {
        let url = folder(handle).appendingPathComponent("\(tab.rawValue).json")
        if let data = try? encoder.encode(users) { try? data.write(to: url, options: .atomic) }
        update(handle) { $0.userCounts[tab.rawValue] = users.count }
    }

    func finish(_ handle: String) {
        let size = Self.size(of: folder(handle))
        update(handle, now: true) { profile in
            profile.status = .complete
            profile.note = ""
            profile.bytes = size
        }
    }

    func delete(_ handle: String) {
        let key = handle.lowercased()
        saveTasks[key]?.cancel()
        saveTasks[key] = nil
        profiles[key] = nil
        postCache = postCache.filter { !$0.key.hasPrefix(key + "/") }
        try? FileManager.default.removeItem(at: folder(handle))
    }

    func deleteAll() {
        for key in Array(profiles.keys) { delete(key) }
    }

    /// Erases everything (the session cache when the app closes).
    func wipe() {
        saveTasks.values.forEach { $0.cancel() }
        saveTasks = [:]
        profiles = [:]
        postCache = [:]
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    nonisolated static func size(of folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // MARK: Internals

    private static func cacheKey(_ handle: String, _ tab: ProfileTab, _ key: String) -> String {
        "\(handle.lowercased())/\(tab.rawValue)/\(key)"
    }

    private func remember(_ post: StoredPost, _ cacheKey: String) {
        if postCache.count > 400 { postCache.removeAll() }
        postCache[cacheKey] = post
    }

    /// profile.json is rewritten at most every couple of seconds while a download runs.
    private func persist(_ key: String, now: Bool) {
        if now {
            saveTasks[key]?.cancel()
            saveTasks[key] = nil
            write(key)
            return
        }
        guard saveTasks[key] == nil else { return }
        saveTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveTasks[key] = nil
            self.write(key)
        }
    }

    private func write(_ key: String) {
        guard let profile = profiles[key], let data = try? encoder.encode(profile) else { return }
        let folder = root.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("profile.json"), options: .atomic)
    }

    private func loadAll() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let url = folder.appendingPathComponent("profile.json")
            guard let data = try? Data(contentsOf: url), var profile = try? decoder.decode(StoredProfile.self, from: data) else { continue }
            if profile.status == .working { profile.status = .paused } // the app closed mid-download
            profiles[profile.id] = profile
        }
    }
}
