import Foundation

/// Instagram archives: Documents/Instagram/<username>/ holds profile.json, avatar.jpg and one file
/// per story or post (plus a cover image for videos). Each update only adds what's new, so stories
/// stay here after they disappear from Instagram.
@MainActor
final class IGArchive: ObservableObject {
    static let shared = IGArchive()

    struct StoredComment: Codable, Hashable {
        let id: String
        /// Parent comment id for a reply, "" for a top-level comment.
        let parent: String
        let author: String
        let verified: Bool
        let text: String
        let time: String
        let likes: Int
    }

    struct Item: Codable, Identifiable, Hashable {
        let key: String
        let kind: String
        let media: String
        /// For a carousel post, every file in order; for a single item, one file.
        var files: [String]
        /// A still for videos ("" for photos or when it couldn't be fetched).
        let cover: String
        let original: String
        let savedAt: Date
        /// Post caption ("" for stories).
        var caption: String = ""
        var likes: Int = 0
        /// Post date as ISO-8601 ("" when unknown).
        var takenAt: String = ""
        /// Comments and replies saved with a post (signed-in archiving only).
        var comments: [StoredComment] = []

        var id: String { kind + ":" + key }
        var isVideo: Bool { media == "video" }
        var isStory: Bool { kind == "story" }
        /// The first file, used as the item's thumbnail/opening media.
        var file: String { files.first ?? "" }
        var replyCount: Int { comments.filter { !$0.parent.isEmpty }.count }

        private enum CodingKeys: String, CodingKey {
            // `file` is read for backward compatibility (decode) but never written; `files` replaces it.
            case key, kind, media, files, file, cover, original, savedAt, caption, likes, takenAt, comments
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(kind, forKey: .kind)
            try c.encode(media, forKey: .media)
            try c.encode(files, forKey: .files)
            try c.encode(cover, forKey: .cover)
            try c.encode(original, forKey: .original)
            try c.encode(savedAt, forKey: .savedAt)
            try c.encode(caption, forKey: .caption)
            try c.encode(likes, forKey: .likes)
            try c.encode(takenAt, forKey: .takenAt)
            try c.encode(comments, forKey: .comments)
        }

        init(key: String, kind: String, media: String, files: [String], cover: String, original: String,
             savedAt: Date, caption: String = "", likes: Int = 0, takenAt: String = "", comments: [StoredComment] = []) {
            self.key = key; self.kind = kind; self.media = media; self.files = files; self.cover = cover
            self.original = original; self.savedAt = savedAt; self.caption = caption; self.likes = likes
            self.takenAt = takenAt; self.comments = comments
        }

        /// Tolerant decode: archives written before carousels/comments stored a single `file`.
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            kind = try c.decode(String.self, forKey: .kind)
            media = try c.decode(String.self, forKey: .media)
            if let many = try? c.decode([String].self, forKey: .files) {
                files = many
            } else if let one = try? c.decode(String.self, forKey: .file) {
                files = [one]
            } else {
                files = []
            }
            cover = (try? c.decode(String.self, forKey: .cover)) ?? ""
            original = (try? c.decode(String.self, forKey: .original)) ?? ""
            savedAt = (try? c.decode(Date.self, forKey: .savedAt)) ?? Date()
            caption = (try? c.decode(String.self, forKey: .caption)) ?? ""
            likes = (try? c.decode(Int.self, forKey: .likes)) ?? 0
            takenAt = (try? c.decode(String.self, forKey: .takenAt)) ?? ""
            comments = (try? c.decode([StoredComment].self, forKey: .comments)) ?? []
        }
    }

    struct Account: Codable, Identifiable {
        var handle: String
        var bio: String
        var stats: [Stat]
        /// Newest first.
        var stories: [Item]
        /// Newest first, in the order the site lists them.
        var posts: [Item]
        var createdAt: Date
        var updatedAt: Date
        /// The last problem while saving, shown on the archive screen ("" when the last update went fine).
        var note: String
        /// true once posts were archived with a signed-in session (full history + comments).
        var signedIn = false

        var id: String { handle.lowercased() }

        private enum CodingKeys: String, CodingKey {
            case handle, bio, stats, stories, posts, createdAt, updatedAt, note, signedIn
        }

        init(handle: String, bio: String, stats: [Stat], stories: [Item], posts: [Item],
             createdAt: Date, updatedAt: Date, note: String, signedIn: Bool = false) {
            self.handle = handle; self.bio = bio; self.stats = stats; self.stories = stories; self.posts = posts
            self.createdAt = createdAt; self.updatedAt = updatedAt; self.note = note; self.signedIn = signedIn
        }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            handle = try c.decode(String.self, forKey: .handle)
            bio = (try? c.decode(String.self, forKey: .bio)) ?? ""
            stats = (try? c.decode([Stat].self, forKey: .stats)) ?? []
            stories = (try? c.decode([Item].self, forKey: .stories)) ?? []
            posts = (try? c.decode([Item].self, forKey: .posts)) ?? []
            createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
            updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
            note = (try? c.decode(String.self, forKey: .note)) ?? ""
            signedIn = (try? c.decode(Bool.self, forKey: .signedIn)) ?? false
        }
    }

    @Published private(set) var accounts: [String: Account] = [:]
    /// What's happening right now for an account ("Saving 3 of 14"), for status lines.
    @Published private(set) var progress: [String: String] = [:]

    let root: URL
    private var running: Set<String> = []
    private let session: URLSession

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Instagram", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        loadAll()
    }

    var sortedAccounts: [Account] { accounts.values.sorted { $0.updatedAt > $1.updatedAt } }

    func account(_ handle: String) -> Account? { accounts[handle.lowercased()] }
    func has(_ handle: String) -> Bool { accounts[handle.lowercased()] != nil }
    func isWorking(_ handle: String) -> Bool { running.contains(handle.lowercased()) }

    func folder(_ handle: String) -> URL { root.appendingPathComponent(handle.lowercased(), isDirectory: true) }

    func fileURL(_ handle: String, _ name: String) -> URL? {
        name.isEmpty ? nil : folder(handle).appendingPathComponent(name)
    }

    func avatarURL(_ handle: String) -> URL? {
        let url = folder(handle).appendingPathComponent("avatar.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func size(_ handle: String) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder(handle), includingPropertiesForKeys: keys) else { return 0 }
        return files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: Set(keys)).fileSize) ?? 0)
        }
    }

    // MARK: Saving

    /// Saves the stories and posts that aren't archived yet. Returns how many files were added.
    @discardableResult
    func absorb(_ profile: IGProfile, stories: [IGItem], posts: [IGItem]) async -> Int {
        let key = profile.handle.lowercased()
        guard !key.isEmpty, !running.contains(key) else { return 0 }
        running.insert(key)
        defer {
            running.remove(key)
            progress[key] = nil
        }
        return await store(profile, stories: stories, posts: posts)
    }

    /// Opens the account out of sight, reads its stories and posts, and saves what's new.
    /// Returns a short sentence for a toast.
    func update(_ handle: String) async -> String {
        let key = handle.lowercased()
        guard !running.contains(key) else { return "@\(handle) is already being saved." }
        running.insert(key)
        progress[key] = "Opening @\(handle)"
        defer {
            running.remove(key)
            progress[key] = nil
        }
        let engine = IGEngine(handle: handle, headless: true)
        defer { engine.teardown() }
        guard let profile = await engine.readProfile() else {
            let why = engine.isCaptcha ? "the site wants a captcha. Open the live profile to solve it." : engine.problem
            note(key, why)
            return "Couldn't update @\(handle): \(why)"
        }
        if profile.isPrivate {
            note(key, "This account is private now, so nothing new can be saved.")
            return "@\(handle) is private, so nothing new was saved."
        }
        progress[key] = "Reading stories"
        let stories = await engine.readTab(.stories)
        progress[key] = "Reading posts"
        let posts = await engine.readTab(.posts)
        let saved = await store(profile, stories: stories?.items ?? [], posts: posts?.items ?? [])
        return saved == 0 ? "@\(handle) is up to date." : "Saved \(saved) new from @\(handle)."
    }

    func delete(_ handle: String) {
        let key = handle.lowercased()
        try? FileManager.default.removeItem(at: folder(key))
        accounts[key] = nil
        DebugLog.shared.add(.store, "Deleted the Instagram archive of @\(handle)")
    }

    private func store(_ profile: IGProfile, stories: [IGItem], posts: [IGItem]) async -> Int {
        let key = profile.handle.lowercased()
        let now = Date()
        var account = accounts[key] ?? Account(handle: profile.handle, bio: profile.bio, stats: profile.stats,
                                               stories: [], posts: [], createdAt: now, updatedAt: now, note: "")
        account.handle = profile.handle
        account.bio = profile.bio
        if !profile.stats.isEmpty { account.stats = profile.stats }
        let dir = folder(key)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            DebugLog.shared.error(.store, "Couldn't create the Instagram archive for @\(profile.handle): \(error.localizedDescription)")
            return 0
        }
        accounts[key] = account
        write(account)
        if let avatar = profile.avatarURL, let data = await fetchData(avatar) {
            try? data.write(to: dir.appendingPathComponent("avatar.jpg"), options: .atomic)
        }

        let haveStories = Set(account.stories.map(\.key))
        let havePosts = Set(account.posts.map(\.key))
        let newItems = stories.filter { !haveStories.contains($0.key) } + posts.filter { !havePosts.contains($0.key) }
        var saved = 0, failed = 0
        let olderPosts = account.posts
        var addedPosts: [Item] = []
        for item in newItems {
            if Task.isCancelled { break }
            progress[key] = "Saving \(saved + failed + 1) of \(newItems.count)"
            guard let stored = await download(item, into: dir) else {
                failed += 1
                continue
            }
            saved += 1
            if stored.isStory {
                account.stories.insert(stored, at: 0)
            } else {
                addedPosts.append(stored)
                account.posts = addedPosts + olderPosts
            }
            account.updatedAt = Date()
            accounts[key] = account
            write(account)
        }
        account.note = failed > 0 ? "\(failed) couldn't be saved; the next update tries them again." : ""
        account.updatedAt = Date()
        accounts[key] = account
        write(account)
        DebugLog.shared.add(.store, "Instagram archive @\(profile.handle): \(saved) saved, \(failed) failed, \(newItems.count) new")
        return saved
    }

    /// Saves one post read by the signed-in session: all carousel media plus the full comment
    /// threads. Replaces an existing copy of the same post (to add comments gathered later).
    func absorbSignedInPost(_ handle: String, grid: IGGridItem, detail: IGPostDetail, profileTotal: Int) async -> Bool {
        let key = handle.lowercased()
        let dir = folder(key)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            DebugLog.shared.error(.store, "Couldn't create the Instagram archive for @\(handle): \(error.localizedDescription)")
            return false
        }
        var files: [String] = []
        var cover = ""
        let base = "post-" + Self.safe(detail.code.isEmpty ? grid.code : detail.code)
        let media = detail.media.isEmpty ? [] : detail.media
        var anyVideo = false
        for (i, m) in media.enumerated() {
            guard let url = m.mediaURL, let temp = await fetchFile(url) else { continue }
            let ext = Self.fileExtension(of: temp, media: m.isVideo ? "video" : "image", filename: "")
            let name = media.count > 1 ? "\(base)-\(i + 1).\(ext)" : "\(base).\(ext)"
            let target = dir.appendingPathComponent(name)
            do {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: temp, to: target)
                files.append(name)
            } catch {
                DebugLog.shared.warn(.store, "Couldn't keep an Instagram post file: \(error.localizedDescription)")
                continue
            }
            if (ext == "mp4" || ext == "mov"), cover.isEmpty, let poster = m.posterURL, let data = await fetchData(poster) {
                let coverName = base + "-cover.jpg"
                if (try? data.write(to: dir.appendingPathComponent(coverName), options: .atomic)) != nil { cover = coverName }
                anyVideo = true
            } else if ext == "mp4" || ext == "mov" {
                anyVideo = true
            }
        }
        guard !files.isEmpty else {
            DebugLog.shared.warn(.store, "Instagram post \(detail.code) had no saveable media")
            return false
        }
        let comments = detail.comments.map { c in
            StoredComment(id: c.id, parent: c.parent, author: c.author, verified: c.verified, text: c.text, time: c.time, likes: c.likes)
        }
        let item = Item(key: detail.code.isEmpty ? grid.code : detail.code, kind: "post",
                        media: anyVideo && files.count == 1 ? "video" : (grid.video && files.count == 1 ? "video" : "image"),
                        files: files, cover: cover, original: "", savedAt: Date(),
                        caption: detail.caption, likes: detail.likes, takenAt: detail.date, comments: comments)

        let now = Date()
        var account = accounts[key] ?? Account(handle: detail.author.isEmpty ? handle : detail.author, bio: "", stats: [],
                                               stories: [], posts: [], createdAt: now, updatedAt: now, note: "", signedIn: true)
        account.signedIn = true
        account.posts.removeAll { $0.key == item.key }
        account.posts.append(item)
        // Newest first: signed-in grid order is newest-first, and takenAt refines it when present.
        account.posts.sort { ($0.takenAt, $0.savedAt) > ($1.takenAt, $1.savedAt) }
        account.updatedAt = Date()
        accounts[key] = account
        write(account)
        DebugLog.shared.add(.store, "Saved Instagram post \(item.key) of @\(handle): \(files.count) file(s), \(comments.count) comments")
        return true
    }

    /// Records that an account has been archived signed-in, and refreshes its header fields.
    func markSignedIn(_ handle: String, profileCount: Int, bio: String, stats: [Stat]) {
        let key = handle.lowercased()
        guard var account = accounts[key] else { return }
        account.signedIn = true
        if !bio.isEmpty { account.bio = bio }
        if !stats.isEmpty { account.stats = stats }
        account.updatedAt = Date()
        accounts[key] = account
        write(account)
    }

    private func note(_ key: String, _ text: String) {
        guard var account = accounts[key] else { return }
        account.note = text
        accounts[key] = account
        write(account)
    }

    // MARK: Files

    private func download(_ item: IGItem, into dir: URL) async -> Item? {
        guard let url = item.mediaURL, let temp = await fetchFile(url) else { return nil }
        let ext = Self.fileExtension(of: temp, media: item.media, filename: item.filename)
        let base = (item.isStory ? "story-" : "post-") + Self.safe(item.key)
        let name = base + "." + ext
        let target = dir.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            DebugLog.shared.warn(.store, "Couldn't keep an Instagram \(item.kind): \(error.localizedDescription)")
            return nil
        }
        let isVideo = ext == "mp4" || ext == "mov"
        var cover = ""
        if isVideo, let thumb = item.thumbURL, let data = await fetchData(thumb) {
            let coverName = base + "-cover.jpg"
            if (try? data.write(to: dir.appendingPathComponent(coverName), options: .atomic)) != nil { cover = coverName }
        }
        return Item(key: item.key, kind: item.kind, media: isVideo ? "video" : "image", files: [name], cover: cover,
                    original: item.filename, savedAt: Date())
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(WebFactory.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer = LinkRules.referer(for: url) { request.setValue(referer, forHTTPHeaderField: "Referer") }
        return request
    }

    private func fetchFile(_ url: URL) async -> URL? {
        do {
            let (temp, response) = try await session.download(for: request(url))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                DebugLog.shared.warn(.store, "Instagram media answered \(http.statusCode) from \(url.host ?? "?")")
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
            return temp
        } catch {
            DebugLog.shared.warn(.store, "Instagram media download failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchData(_ url: URL) async -> Data? {
        guard let result = try? await session.data(for: request(url)) else { return nil }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return data.isEmpty ? nil : data
    }

    private func write(_ account: Account) {
        let url = folder(account.handle).appendingPathComponent("profile.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(account).write(to: url, options: .atomic)
        } catch {
            DebugLog.shared.warn(.store, "Couldn't write the Instagram archive index for @\(account.handle): \(error.localizedDescription)")
        }
    }

    private func loadAll() {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found: [String: Account] = [:]
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("profile.json")),
                  let account = try? decoder.decode(Account.self, from: data) else { continue }
            found[account.id] = account
        }
        accounts = found
    }

    /// The real type from the file's first bytes, then its name, then what the site said.
    nonisolated static func fileExtension(of file: URL, media: String, filename: String) -> String {
        var head = Data()
        if let handle = try? FileHandle(forReadingFrom: file) {
            head = (try? handle.read(upToCount: 16)) ?? Data()
            try? handle.close()
        }
        let b = [UInt8](head)
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            return ["heic", "heix", "mif1", "msf1"].contains(brand) ? "heic" : "mp4"
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "webp", "heic", "mp4", "mov"].contains(ext) { return ext == "jpeg" ? "jpg" : ext }
        return media == "video" ? "mp4" : "jpg"
    }

    nonisolated static func safe(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String(cleaned.prefix(90))
    }
}
