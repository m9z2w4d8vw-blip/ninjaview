import BackgroundTasks
import Combine
import Foundation
import SwiftUI

/// Background task identifiers, kept outside the main-actor class so the scheduler can name them.
enum WatchTask {
    static let refreshID = "com.parv.ninjaview.check"
    static let processingID = "com.parv.ninjaview.process"
}

/// How NinjaView watches in the background.
enum WatchMode: String, CaseIterable, Identifiable, Codable {
    /// Keeps itself awake with a silent audio session and checks on a short loop.
    case instant
    /// Only checks when open or when iOS wakes it (Background App Refresh).
    case standard

    var id: String { rawValue }
    var title: String { self == .instant ? "Instant" : "Standard" }
}

/// The kinds of activity a notification can be about. Each maps to a tik.ninja tab.
enum Activity: String, CaseIterable, Codable, Identifiable {
    case video, story, repost

    var id: String { rawValue }

    var tab: ProfileTab {
        switch self {
        case .video: return .videos
        case .story: return .stories
        case .repost: return .reposts
        }
    }

    /// What the notification settings call it.
    var title: String {
        switch self {
        case .video: return "Posts"
        case .story: return "Stories"
        case .repost: return "Reposts"
        }
    }

    var detail: String {
        switch self {
        case .video: return "New videos and photo posts"
        case .story: return "New stories"
        case .repost: return "Videos they repost"
        }
    }

    var symbol: String {
        switch self {
        case .video: return "square.grid.3x3"
        case .story: return "circle.dashed"
        case .repost: return "arrow.2.squarepath"
        }
    }

    /// What each site can notify about.
    /// Instagram post notifications are not available: posts come only from the signed-in
    /// session, which the background watcher does not use. Only story notifications work.
    static func kinds(for platform: Platform) -> [Activity] {
        platform == .instagram ? [.story] : allCases
    }

    /// "Posts, Stories and Reposts", in tab order.
    static func list(_ kinds: Set<Activity>) -> String {
        let names = allCases.filter { kinds.contains($0) }.map(\.title)
        switch names.count {
        case 0: return "Nothing"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }
}

/// Watches chosen accounts for new posts, stories and reposts (each kind chosen per account),
/// and notifies when they appear.
///
/// Instant mode keeps the app running with a silent audio session (works through TrollStore,
/// no jailbreak) and checks every poll interval, but only while at least one account is watched.
/// Standard mode checks when the app is open and when iOS wakes it.
///
/// Detection compares the newest items' stable keys per tab with what was seen last. A tab only
/// counts when it loaded cleanly, so a rate-limited check can never make old posts look new.
@MainActor
final class WatchCenter: ObservableObject {
    static let shared = WatchCenter()

    struct Watched: Codable, Identifiable {
        var handle: String
        var name: String
        var platform: Platform
        /// Which kinds of activity notify. Turning the last one off stops watching the account.
        var activities: Set<Activity>
        var seenVideoKeys: [String] = []
        var seenStoryKeys: [String] = []
        var seenRepostKeys: [String] = []
        /// Kinds whose first check is done. That check is silent, so what's already there doesn't notify.
        var baselined: Set<Activity> = []
        var lastChecked: Date?
        var addedAt: Date
        /// TikTok entries keep the bare handle as their key, exactly as before Instagram support.
        var id: String { platform.key(handle) }
        var label: String { platform == .instagram ? "@\(handle) on Instagram" : "@\(handle)" }

        init(handle: String, name: String, activities: Set<Activity>, platform: Platform = .tiktok) {
            self.handle = handle
            self.name = name
            self.platform = platform
            self.activities = activities
            self.addedAt = Date()
        }

        private enum CodingKeys: String, CodingKey {
            case handle, name, platform, activities, seenVideoKeys, seenStoryKeys, seenRepostKeys, baselined, lastChecked, addedAt
        }

        /// Tolerant decoding: a field added later, or stored differently by an earlier build,
        /// gets a safe default instead of failing the whole list.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            handle = try c.decode(String.self, forKey: .handle)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            platform = (try? c.decode(Platform.self, forKey: .platform)) ?? .tiktok
            let kinds = (try? c.decode(Set<Activity>.self, forKey: .activities)) ?? []
            activities = kinds.isEmpty ? Set(Activity.allCases) : kinds
            seenVideoKeys = (try? c.decode([String].self, forKey: .seenVideoKeys)) ?? []
            seenStoryKeys = (try? c.decode([String].self, forKey: .seenStoryKeys)) ?? []
            seenRepostKeys = (try? c.decode([String].self, forKey: .seenRepostKeys)) ?? []
            // Build 7 stored a single Bool here; that reads as "no first look yet", which is safe.
            baselined = (try? c.decode(Set<Activity>.self, forKey: .baselined)) ?? []
            lastChecked = try? c.decode(Date.self, forKey: .lastChecked)
            addedAt = (try? c.decode(Date.self, forKey: .addedAt)) ?? Date()
        }

        func seen(_ activity: Activity) -> [String] {
            switch activity {
            case .video: return seenVideoKeys
            case .story: return seenStoryKeys
            case .repost: return seenRepostKeys
            }
        }

        mutating func setSeen(_ activity: Activity, _ keys: [String]) {
            switch activity {
            case .video: seenVideoKeys = keys
            case .story: seenStoryKeys = keys
            case .repost: seenRepostKeys = keys
            }
        }
    }

    /// What one site said about an account's tabs.
    private struct Reading {
        var current: [Activity: [String]] = [:]
        var name = ""
        var refused = false
        /// Set when the account itself couldn't be read.
        var failure: String? = nil
    }

    /// How one account's check went.
    private enum Outcome {
        case checked(Int)   // how many new items
        case failed
        case refused        // tik.ninja's rate limit, or it refused outright
        case skipped
    }

    @Published private(set) var watched: [Watched]
    @Published private(set) var enabled: Bool
    @Published private(set) var isChecking = false
    @Published private(set) var keepAliveRunning = false
    @Published private(set) var lastResult: String? = nil
    @Published private(set) var lastCheckAt: Date? = nil
    /// tik.ninja asked NinjaView to slow down; automatic checks wait until this time.
    @Published private(set) var restingUntil: Date? = nil

    @Published var mode: WatchMode { didSet { persistMode(); applyMonitoring() } }
    @Published var pollInterval: Double { didSet { UserDefaults.standard.set(pollInterval, forKey: intervalKey) } }
    @Published var watchdog: Bool { didSet { UserDefaults.standard.set(watchdog, forKey: watchdogKey); applyMonitoring() } }
    @Published var timeSensitive: Bool { didSet { UserDefaults.standard.set(timeSensitive, forKey: timeSensitiveKey) } }

    static let intervals: [Double] = [120, 180, 300, 600, 900]

    private let keepAlive = KeepAlive()
    private var loopTask: Task<Void, Never>? = nil
    private var isActive = false
    private var isRunning = false
    private var inFlight: Set<String> = []
    private var refusalStreak = 0
    private let seenCap = 60

    private let watchedKey = "watchedAccounts"
    private let enabledKey = "watchEnabled"
    private let modeKey = "watchMode"
    private let intervalKey = "watchPollInterval"
    private let watchdogKey = "watchWatchdog"
    private let timeSensitiveKey = "watchTimeSensitive"

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [modeKey: WatchMode.instant.rawValue, intervalKey: 180.0,
                                     watchdogKey: true, timeSensitiveKey: true])
        watched = Store.load([Watched].self, key: watchedKey) ?? []
        enabled = defaults.bool(forKey: enabledKey)
        mode = WatchMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .instant
        pollInterval = defaults.double(forKey: intervalKey)
        watchdog = defaults.bool(forKey: watchdogKey)
        timeSensitive = defaults.bool(forKey: timeSensitiveKey)
        keepAlive.onChange = { [weak self] running in self?.keepAliveRunning = running }
    }

    var count: Int { watched.count }

    func activities(for handle: String, platform: Platform = .tiktok) -> Set<Activity> {
        let key = platform.key(handle)
        return watched.first { $0.id == key }?.activities ?? []
    }

    func isWatched(_ handle: String, platform: Platform = .tiktok) -> Bool {
        !activities(for: handle, platform: platform).isEmpty
    }

    var isResting: Bool { (restingUntil ?? .distantPast) > Date() }

    /// What the "Keeping awake" row in Settings shows.
    var keepAwakeStatus: String {
        if mode != .instant { return "Off in Standard mode" }
        if !enabled { return "Off" }
        if watched.isEmpty { return "Waiting for an account" }
        return keepAliveRunning ? "Running" : "Couldn't start"
    }

    // MARK: App lifecycle

    func didFinishLaunching() {
        BackgroundScheduler.scheduleAll()
        applyMonitoring()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            let loopWasRunning = loopTask != nil
            isActive = true
            applyMonitoring()
            // Opening the app gives a fresh check even if the loop was already running.
            if loopWasRunning, Date().timeIntervalSince(lastCheckAt ?? .distantPast) > 10 {
                Task { await runChecks(keys: oldestFirst(limit: 8), trigger: .foreground, budget: 120) }
            }
        case .background:
            isActive = false
            BackgroundScheduler.scheduleAll()
            applyMonitoring()
        default:
            break
        }
    }

    // MARK: Choosing what notifies

    /// Turns one kind of notification on or off for an account. Returns false, changing nothing,
    /// if iOS doesn't allow NinjaView's notifications.
    func set(_ kind: Activity, _ on: Bool, handle: String, name: String, platform: Platform = .tiktok) async -> Bool {
        if on {
            guard await NotificationManager.shared.requestAuthorization() else { return false }
            if !enabled { enabled = true; persistEnabled() }
        }
        let key = platform.key(handle)
        if let index = watched.firstIndex(where: { $0.id == key }) {
            var entry = watched[index]
            if on { entry.activities.insert(kind) } else { entry.activities.remove(kind) }
            if entry.activities.isEmpty {
                watched.remove(at: index)
                DebugLog.shared.add(.watch, "Stopped watching \(entry.label)")
            } else {
                if !name.isEmpty { entry.name = name }
                watched[index] = entry
                DebugLog.shared.add(.watch, "\(entry.label) now notifies about \(Activity.list(entry.activities).lowercased())")
            }
        } else if on {
            let entry = Watched(handle: handle, name: name, activities: [kind], platform: platform)
            watched.append(entry)
            DebugLog.shared.add(.watch, "Watching \(entry.label) for \(kind.title.lowercased()) (\(watched.count) accounts)")
        } else {
            return true
        }
        persistWatched()
        applyMonitoring()
        if on {
            // A silent first look at the newly turned-on kind, so what's already there doesn't notify.
            Task { _ = await checkOne(key, deadline: Date().addingTimeInterval(60)) }
        }
        return true
    }

    func unwatch(_ handle: String, platform: Platform = .tiktok) {
        let key = platform.key(handle)
        watched.removeAll { $0.id == key }
        persistWatched()
        DebugLog.shared.add(.watch, "Stopped watching \(platform == .instagram ? "@\(handle) on Instagram" : "@\(handle)")")
        applyMonitoring()
    }

    func setEnabled(_ on: Bool) async {
        if on {
            guard await NotificationManager.shared.requestAuthorization() else { return }
            enabled = true
        } else {
            enabled = false
        }
        persistEnabled()
        applyMonitoring()
    }

    // MARK: Monitoring

    private var wantsKeepAlive: Bool { enabled && mode == .instant && !watched.isEmpty }

    /// How long Instant mode can go quiet before the "stopped watching" alert fires.
    private var watchdogDelay: TimeInterval { max(600, pollInterval * 4 + 120) }

    func applyMonitoring() {
        if wantsKeepAlive {
            keepAliveRunning = keepAlive.isPlaying ? true : keepAlive.start()
            if watchdog {
                NotificationManager.shared.scheduleWatchdog(after: watchdogDelay)
            } else {
                NotificationManager.shared.cancelWatchdog()
            }
        } else {
            if keepAlive.isPlaying || keepAliveRunning { keepAlive.stop() }
            keepAliveRunning = false
            NotificationManager.shared.cancelWatchdog()
        }
        if (wantsKeepAlive || isActive) && enabled && !watched.isEmpty {
            startLoop()
        } else {
            stopLoop()
        }
    }

    private func startLoop() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.wantsKeepAlive && !self.keepAlive.isPlaying {
                    self.keepAliveRunning = self.keepAlive.start()
                }
                if self.enabled && !self.watched.isEmpty {
                    await self.runChecks(keys: self.watched.map(\.id),
                                         trigger: self.isActive ? .foreground : .instant,
                                         budget: 600)
                }
                // The watchdog follows this loop, so it's pushed back even when checks are resting.
                if self.wantsKeepAlive && self.watchdog {
                    NotificationManager.shared.scheduleWatchdog(after: self.watchdogDelay)
                }
                let seconds = max(60, self.pollInterval)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: Checking

    /// Every watched account, now (the "Check now" button). Runs even while resting.
    func checkNow() async {
        await runChecks(keys: watched.map(\.id), trigger: .manual, budget: 240)
    }

    /// Called by the background tasks. Short, cancellation-aware, and always reschedules.
    func runBackgroundCheck(trigger: CheckTrigger) async -> Bool {
        DebugLog.shared.add(.watch, "\(trigger.rawValue) woke up")
        if enabled, !watched.isEmpty {
            let processing = trigger == .backgroundProcessing
            await runChecks(keys: oldestFirst(limit: processing ? 20 : 6),
                            trigger: trigger,
                            budget: processing ? 170 : 25)
        }
        if wantsKeepAlive && watchdog {
            NotificationManager.shared.scheduleWatchdog(after: watchdogDelay)
        }
        return true
    }

    private func oldestFirst(limit: Int) -> [String] {
        watched.sorted { ($0.lastChecked ?? .distantPast) < ($1.lastChecked ?? .distantPast) }
            .prefix(limit)
            .map(\.id)
    }

    private func runChecks(keys: [String], trigger: CheckTrigger, budget: Double) async {
        guard !isRunning else { return }
        if trigger != .manual, isResting {
            DebugLog.shared.add(.watch, "\(trigger.rawValue) check skipped: tik.ninja asked to slow down, resuming at \(Self.clock(restingUntil))")
            return
        }
        isRunning = true
        isChecking = true
        defer { isRunning = false; isChecking = false }
        let overall = Date().addingTimeInterval(budget)
        var checked = 0, found = 0, failed = 0
        var refused = false
        for key in keys {
            if Task.isCancelled || Date() > overall { break }
            // Leave room so the last account doesn't overrun a short background budget.
            let perAccount = min(overall, Date().addingTimeInterval(45))
            switch await checkOne(key, deadline: perAccount) {
            case .checked(let fresh):
                checked += 1
                found += fresh
            case .failed:
                failed += 1
            case .refused:
                failed += 1
                refused = true
            case .skipped:
                break
            }
            // The limit applies to the whole connection, so more requests now only make it worse.
            if refused { break }
        }
        if refused {
            refusalStreak += 1
            let minutes = min(60.0, 5.0 * pow(2.0, Double(refusalStreak - 1)))
            restingUntil = Date().addingTimeInterval(minutes * 60)
            DebugLog.shared.warn(.watch, "tik.ninja is refusing requests; automatic checks rest for \(Int(minutes)) min")
        } else if checked > 0 {
            refusalStreak = 0
            restingUntil = nil
        }
        lastCheckAt = Date()
        var summary = "Checked \(checked), \(found) new"
        if failed > 0 { summary += ", \(failed) couldn't be checked" }
        if refused { summary += ". tik.ninja asked NinjaView to slow down, so automatic checks resume at \(Self.clock(restingUntil))." }
        lastResult = summary
        DebugLog.shared.add(.watch, "\(trigger.rawValue) check: \(summary)", level: failed > 0 ? .warning : .info)
    }

    /// One account: reads the tabs for the kinds it watches (from TikTok or Instagram), notifies
    /// about anything new, and records what it saw. A kind is only compared, or given its silent
    /// first look, when its tab loaded cleanly, so a refused or half-loaded tab can't make old posts
    /// look new later.
    private func checkOne(_ key: String, deadline: Date) async -> Outcome {
        guard let start = watched.first(where: { $0.id == key }), !inFlight.contains(key) else { return .skipped }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        let kinds = Activity.kinds(for: start.platform).filter { start.activities.contains($0) }
        let started = Date()
        let reading: Reading
        if start.platform == .instagram {
            reading = await readInstagram(start.handle, kinds: kinds, deadline: deadline)
        } else {
            reading = await readTikTok(start.handle, kinds: kinds, deadline: deadline)
        }
        if let failure = reading.failure {
            DebugLog.shared.warn(.watch, "Couldn't reach \(start.label) in \(Self.ms(started)) ms: \(failure)")
            return reading.refused ? .refused : .failed
        }
        let current = reading.current

        guard let index = watched.firstIndex(where: { $0.id == key }) else { return .skipped }
        var entry = watched[index]
        var totalNew = 0
        var firstLooks: [String] = []
        for kind in Activity.allCases {
            guard let keys = current[kind], entry.activities.contains(kind) else { continue }
            let seen = Set(entry.seen(kind))
            let fresh = keys.filter { !seen.contains($0) }
            if entry.baselined.contains(kind) {
                if !fresh.isEmpty {
                    totalNew += fresh.count
                    NotificationManager.shared.notify(handle: entry.handle, name: entry.name, activity: kind,
                                                      count: fresh.count, timeSensitive: timeSensitive, platform: entry.platform)
                }
            } else {
                firstLooks.append(kind.title.lowercased())
                entry.baselined.insert(kind)
            }
            // Keep newest keys first, capped, so items don't re-notify and the list stays small.
            var merged = keys
            for seenKey in entry.seen(kind) where !merged.contains(seenKey) { merged.append(seenKey) }
            entry.setSeen(kind, Array(merged.prefix(seenCap)))
        }
        if !current.isEmpty { entry.lastChecked = Date() }
        if !reading.name.isEmpty { entry.name = reading.name }
        watched[index] = entry
        persistWatched()
        let note = firstLooks.isEmpty ? "" : " (silent first look at \(firstLooks.joined(separator: ", ")))"
        DebugLog.shared.add(.watch, "Checked \(entry.label): \(totalNew) new\(note), \(current.count) of \(kinds.count) tabs usable, \(Self.ms(started)) ms")
        if reading.refused { return .refused }
        return current.isEmpty ? .failed : .checked(totalNew)
    }

    private func readTikTok(_ handle: String, kinds: [Activity], deadline: Date) async -> Reading {
        var reading = Reading()
        let engine = ProfileEngine(route: Route(query: handle, handle: handle), headless: true)
        engine.start()
        guard await waitUntilReady(engine, until: deadline), let header = engine.header else {
            let reason = Self.failureText(engine.phase)
            engine.teardown()
            reading.failure = reason
            reading.refused = Self.isRefusal(reason)
            return reading
        }
        reading.name = header.name
        for kind in kinds {
            if Task.isCancelled || Date() > deadline { break }
            await engine.load(kind.tab)
            let state = engine.tabs[kind.tab]
            if let problem = Self.tabProblem(state) {
                DebugLog.shared.warn(.watch, "@\(handle) \(kind.title.lowercased()) not used this time: \(problem)")
                if Self.isRefusal(problem) { reading.refused = true; break }
                continue
            }
            reading.current[kind] = (state?.items ?? []).prefix(24).map { StableKey.of($0, tab: kind.tab) }
        }
        engine.teardown()
        return reading
    }

    /// Instagram through the viewer site. When the account has an archive, whatever new stories
    /// and posts this check saw are saved into it too, so stories are kept before they expire.
    private func readInstagram(_ handle: String, kinds: [Activity], deadline: Date) async -> Reading {
        var reading = Reading()
        let engine = IGEngine(handle: handle, headless: true)
        defer { engine.teardown() }
        let budget = max(8, deadline.timeIntervalSinceNow - 2)
        guard let profile = await engine.readProfile(timeout: min(25, budget)), engine.phase == .ready else {
            let problem = engine.problem.isEmpty ? "no answer before the time limit" : engine.problem
            reading.failure = problem
            reading.refused = engine.isCaptcha || Self.isRefusal(problem)
            return reading
        }
        var stories: [IGItem] = []
        // Posts are no longer read from the viewer site; only stories are watched here.
        for kind in kinds where kind == .story {
            if Task.isCancelled || Date() > deadline { break }
            let left = max(6, min(25, deadline.timeIntervalSinceNow - 1))
            guard let tab = await engine.readTab(.stories, timeout: left) else { continue }
            if tab.isClean {
                reading.current[kind] = tab.items.map(\.key)
                stories = tab.items
            } else {
                DebugLog.shared.warn(.watch, "@\(handle) on Instagram, stories not used this time: \(tab.message.isEmpty ? tab.status : tab.message)")
                if tab.status == "captcha" || Self.isRefusal(tab.message) {
                    reading.refused = true
                    break
                }
            }
        }
        if IGArchive.shared.has(handle), !stories.isEmpty {
            await IGArchive.shared.absorb(profile, stories: stories, posts: [])
        }
        return reading
    }

    private func waitUntilReady(_ engine: ProfileEngine, until deadline: Date) async -> Bool {
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

    /// Why a tab's result can't be trusted, or nil if it loaded cleanly (an empty tab is clean).
    private static func tabProblem(_ state: TabState?) -> String? {
        guard let state else { return "it didn't load" }
        if let error = state.error { return error }
        if !state.loaded { return "it didn't finish loading" }
        if state.items.isEmpty, looksLikeSiteError(state.message) { return state.message }
        return nil
    }

    /// tik.ninja shows its errors where results would be, e.g. "Server error, please try again. (HTTP 429)".
    private static func looksLikeSiteError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["error", "try again", "forbidden", "429", "too many", "rate limit"].contains { lower.contains($0) }
    }

    /// Errors that mean "slow down": the rate limit, or the site refusing outright.
    private static func isRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["429", "too many", "forbidden", "403", "rate limit"].contains { lower.contains($0) }
    }

    private static func failureText(_ phase: ProfileEngine.Phase) -> String {
        if case .failed(let failure) = phase { return "\(failure.title). \(failure.detail)" }
        return "no answer before the time limit"
    }

    private static func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    private static func clock(_ date: Date?) -> String {
        date?.formatted(date: .omitted, time: .shortened) ?? "later"
    }

    // MARK: Persistence

    private func persistWatched() { Store.save(watched, key: watchedKey) }
    private func persistEnabled() { UserDefaults.standard.set(enabled, forKey: enabledKey) }
    private func persistMode() { UserDefaults.standard.set(mode.rawValue, forKey: modeKey) }
}
