import BackgroundTasks
import Combine
import Foundation

/// Task identifier, kept outside the main-actor class so the App scene and the
/// scheduler can both name it.
enum WatchTask {
    static let refreshID = "com.parv.ninjaview.check"
}

/// Watches chosen accounts for new posts. iOS wakes the app for a background check
/// when it decides to (a few times a day, not on a fixed clock, and never while the
/// app is force-quit); the app also checks each time you open it. New posts raise a
/// local notification. Nothing here needs a TikTok login.
///
/// A check is cheap: it opens a hidden tik.ninja page for the account, reads the post
/// count (and, when there's time, the newest post), and compares with what it saw last.
@MainActor
final class WatchCenter: ObservableObject {
    static let shared = WatchCenter()

    struct Watched: Codable, Identifiable {
        var handle: String
        var name: String
        /// The signature last seen: how many posts, and the newest post's stable key.
        var postCount: Int?
        var newestKey: String?
        var lastChecked: Date?
        var addedAt: Date
        var id: String { handle.lowercased() }
    }

    @Published private(set) var watched: [Watched]
    @Published private(set) var enabled: Bool
    @Published private(set) var isChecking = false
    @Published private(set) var lastResult: String? = nil

    private let watchedKey = "watchedAccounts"
    private let enabledKey = "watchEnabled"
    private let foregroundKey = "watchLastForeground"
    private var isRunning = false

    private init() {
        watched = Store.load([Watched].self, key: watchedKey) ?? []
        enabled = UserDefaults.standard.bool(forKey: enabledKey)
    }

    var count: Int { watched.count }

    func isWatched(_ handle: String) -> Bool { watched.contains { $0.id == handle.lowercased() } }

    // MARK: Membership

    /// true/false for now watching, or nil if notifications aren't permitted.
    func toggle(_ header: ProfileHeader) async -> Bool? {
        if isWatched(header.handle) {
            unwatch(header.handle)
            return false
        }
        guard await NotificationManager.shared.requestAuthorization() else { return nil }
        if !enabled { enabled = true; persistEnabled() }
        var entry = Watched(handle: header.handle, name: header.name, postCount: postCount(from: header),
                            newestKey: nil, lastChecked: nil, addedAt: Date())
        _ = entry // seeded below after append so persistence sees the baseline
        watched.append(entry)
        persistWatched()
        DebugLog.shared.add(.watch, "Watching @\(header.handle) (\(watched.count) total)")
        schedule()
        // Record a baseline now so the first scheduled check doesn't call every post "new".
        Task { _ = await checkOne(header.handle, deep: true) }
        return true
    }

    func unwatch(_ handle: String) {
        watched.removeAll { $0.id == handle.lowercased() }
        persistWatched()
        DebugLog.shared.add(.watch, "Stopped watching @\(handle)")
        if watched.isEmpty { cancelSchedule() }
    }

    func setEnabled(_ on: Bool) async {
        if on {
            guard await NotificationManager.shared.requestAuthorization() else { return }
            enabled = true
            persistEnabled()
            schedule()
        } else {
            enabled = false
            persistEnabled()
            cancelSchedule()
        }
    }

    // MARK: Checking

    /// Every watched account, now, with a toast summary (the "Check now" button).
    func checkNow() async {
        await runChecks(handles: watched.map(\.handle), deep: true, reason: "manual", budget: 180)
    }

    /// On returning to the app: check the accounts checked longest ago, at most every 10 minutes.
    func runForegroundCheck() {
        guard enabled, !watched.isEmpty else { return }
        let last = UserDefaults.standard.double(forKey: foregroundKey)
        let now = Date().timeIntervalSince1970
        guard now - last > 600 else { return }
        UserDefaults.standard.set(now, forKey: foregroundKey)
        Task { await runChecks(handles: oldestFirst(limit: 8), deep: true, reason: "foreground", budget: 90) }
    }

    /// Called by the background task. Short, cancellation-aware, and it always reschedules.
    func runBackgroundCheck() async {
        DebugLog.shared.add(.watch, "Background check woke up")
        if enabled, !watched.isEmpty {
            await runChecks(handles: oldestFirst(limit: 6), deep: false, reason: "background", budget: 25)
        }
        schedule()
        DebugLog.shared.add(.watch, "Background check finished")
    }

    private func oldestFirst(limit: Int) -> [String] {
        watched.sorted { ($0.lastChecked ?? .distantPast) < ($1.lastChecked ?? .distantPast) }
            .prefix(limit)
            .map(\.handle)
    }

    private func runChecks(handles: [String], deep: Bool, reason: String, budget: Double) async {
        guard !isRunning else { return }
        isRunning = true
        isChecking = true
        defer { isRunning = false; isChecking = false }
        let deadline = Date().addingTimeInterval(budget)
        var checked = 0, found = 0, failed = 0
        for handle in handles {
            if Task.isCancelled || Date() > deadline { break }
            if let new = await checkOne(handle, deep: deep) {
                checked += 1
                if new > 0 {
                    found += new
                    if let entry = watched.first(where: { $0.id == handle.lowercased() }) {
                        NotificationManager.shared.notifyNewPosts(handle: entry.handle, name: entry.name, count: new)
                    }
                }
            } else {
                failed += 1
            }
        }
        lastResult = "Checked \(checked), \(found) new" + (failed > 0 ? ", \(failed) couldn't be reached" : "")
        DebugLog.shared.add(.watch, "\(reason.capitalized) check: \(lastResult ?? "")")
    }

    /// One account. Updates its stored signature and returns how many new posts, or nil
    /// if tik.ninja couldn't be reached.
    private func checkOne(_ handle: String, deep: Bool) async -> Int? {
        guard let index = watched.firstIndex(where: { $0.id == handle.lowercased() }) else { return nil }
        let started = Date()
        let engine = ProfileEngine(route: Route(query: handle, handle: handle), headless: true)
        engine.start()
        guard await waitUntilReady(engine, seconds: deep ? 15 : 10), let header = engine.header else {
            engine.teardown()
            DebugLog.shared.warn(.watch, "Couldn't reach @\(handle) in \(Self.ms(started)) ms")
            return nil
        }
        let count = postCount(from: header)
        var newestKey = watched[index].newestKey
        if deep {
            await engine.load(.videos)
            if let first = engine.tabs[.videos]?.items.first {
                newestKey = StableKey.of(first, tab: .videos)
            }
        }
        engine.teardown()

        let previousCount = watched[index].postCount
        let previousKey = watched[index].newestKey
        var new = 0
        if let previousCount, let count, count > previousCount {
            new = count - previousCount
        } else if deep, let previousKey, let newestKey, newestKey != previousKey,
                  previousCount == nil || count == nil || count == previousCount {
            new = 1
        }

        // The list may have changed while the page loaded; find the row again before saving.
        guard let saveIndex = watched.firstIndex(where: { $0.id == handle.lowercased() }) else { return new }
        if let count { watched[saveIndex].postCount = count }
        if let newestKey { watched[saveIndex].newestKey = newestKey }
        if !header.name.isEmpty { watched[saveIndex].name = header.name }
        watched[saveIndex].lastChecked = Date()
        persistWatched()
        DebugLog.shared.add(.watch, "Checked @\(handle): \(count.map(String.init) ?? "?") posts, \(new) new, \(Self.ms(started)) ms")
        return new
    }

    private func waitUntilReady(_ engine: ProfileEngine, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Task.isCancelled { return false }
            switch engine.phase {
            case .ready: return true
            case .failed: return false
            case .loading: break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func postCount(from header: ProfileHeader) -> Int? {
        for stat in header.stats {
            let label = stat.label.lowercased()
            if label == "videos" || label == "posts" { return CompactNumber.parse(stat.value) }
        }
        return nil
    }

    private static func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    // MARK: Scheduling

    func schedule() {
        guard enabled, !watched.isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: WatchTask.refreshID)
        // iOS treats this as the earliest it may run, then picks the moment itself.
        request.earliestBeginDate = Date().addingTimeInterval(3600)
        do {
            try BGTaskScheduler.shared.submit(request)
            DebugLog.shared.add(.watch, "Asked iOS for the next background check in about an hour")
        } catch {
            DebugLog.shared.warn(.watch, "Couldn't schedule a background check: \(error.localizedDescription). Background App Refresh may be off for NinjaView.")
        }
    }

    private func cancelSchedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: WatchTask.refreshID)
        DebugLog.shared.add(.watch, "Cancelled scheduled background checks")
    }

    // MARK: Persistence

    private func persistWatched() { Store.save(watched, key: watchedKey) }
    private func persistEnabled() { UserDefaults.standard.set(enabled, forKey: enabledKey) }
}
