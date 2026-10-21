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
enum Activity: String, CaseIterable {
    case video, story, repost

    var tab: ProfileTab {
        switch self {
        case .video: return .videos
        case .story: return .stories
        case .repost: return .reposts
        }
    }
}

/// Watches chosen accounts for new posts, stories and reposts, and notifies when they appear.
///
/// Instant mode keeps the app running with a silent audio session (works through TrollStore,
/// no jailbreak) and checks every poll interval. Standard mode checks when the app is open and
/// when iOS wakes it. Both check the moment you open the app, and there's a Check now button.
///
/// Detection is by the newest items' stable keys per tab, compared with what was seen last.
@MainActor
final class WatchCenter: ObservableObject {
    static let shared = WatchCenter()

    struct Watched: Codable, Identifiable {
        var handle: String
        var name: String
        var seenVideoKeys: [String] = []
        var seenStoryKeys: [String] = []
        var seenRepostKeys: [String] = []
        /// First check done, so later checks may notify (the baseline check is silent).
        var baselined = false
        var lastChecked: Date?
        var addedAt: Date
        var id: String { handle.lowercased() }

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

    @Published private(set) var watched: [Watched]
    @Published private(set) var enabled: Bool
    @Published private(set) var isChecking = false
    @Published private(set) var keepAliveRunning = false
    @Published private(set) var lastResult: String? = nil
    @Published private(set) var lastCheckAt: Date? = nil

    @Published var mode: WatchMode { didSet { persistMode(); applyMonitoring() } }
    @Published var pollInterval: Double { didSet { UserDefaults.standard.set(pollInterval, forKey: intervalKey) } }
    @Published var watchdog: Bool { didSet { UserDefaults.standard.set(watchdog, forKey: watchdogKey); applyMonitoring() } }
    @Published var timeSensitive: Bool { didSet { UserDefaults.standard.set(timeSensitive, forKey: timeSensitiveKey) } }

    static let intervals: [Double] = [120, 180, 300, 600, 900]

    private let keepAlive = KeepAlive()
    private var loopTask: Task<Void, Never>? = nil
    private var isActive = false
    private let seenCap = 60

    private let watchedKey = "watchedAccounts"
    private let enabledKey = "watchEnabled"
    private let modeKey = "watchMode"
    private let intervalKey = "watchPollInterval"
    private let watchdogKey = "watchWatchdog"
    private let timeSensitiveKey = "watchTimeSensitive"
    private let foregroundKey = "watchLastForeground"
    private var isRunning = false

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
    }

    var count: Int { watched.count }

    func isWatched(_ handle: String) -> Bool { watched.contains { $0.id == handle.lowercased() } }

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
                Task { await runChecks(handles: oldestFirst(limit: 8), trigger: .foreground, budget: 120) }
            }
        case .background:
            isActive = false
            BackgroundScheduler.scheduleAll()
            applyMonitoring()
        default:
            break
        }
    }

    // MARK: Membership

    /// true/false for now watching, or nil if notifications aren't permitted.
    func toggle(_ header: ProfileHeader) async -> Bool? {
        if isWatched(header.handle) {
            unwatch(header.handle)
            return false
        }
        guard await NotificationManager.shared.requestAuthorization() else { return nil }
        if !enabled { enabled = true; persistEnabled() }
        watched.append(Watched(handle: header.handle, name: header.name, addedAt: Date()))
        persistWatched()
        DebugLog.shared.add(.watch, "Watching @\(header.handle) (\(watched.count) total)")
        applyMonitoring()
        // A silent baseline check so the first real check doesn't report everything as new.
        Task { _ = await checkOne(header.handle, deadline: Date().addingTimeInterval(60)) }
        return true
    }

    func unwatch(_ handle: String) {
        watched.removeAll { $0.id == handle.lowercased() }
        persistWatched()
        DebugLog.shared.add(.watch, "Stopped watching @\(handle)")
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
                    await self.runChecks(handles: self.watched.map(\.handle),
                                         trigger: self.isActive ? .foreground : .instant,
                                         budget: 600)
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

    /// Every watched account, now, with a toast summary (the "Check now" button).
    func checkNow() async {
        await runChecks(handles: watched.map(\.handle), trigger: .manual, budget: 240)
    }

    /// Called by the background tasks. Short, cancellation-aware, and always reschedules.
    func runBackgroundCheck(trigger: CheckTrigger) async -> Bool {
        DebugLog.shared.add(.watch, "\(trigger.rawValue) woke up")
        if enabled, !watched.isEmpty {
            let processing = trigger == .backgroundProcessing
            await runChecks(handles: oldestFirst(limit: processing ? 20 : 6),
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
            .map(\.handle)
    }

    private func runChecks(handles: [String], trigger: CheckTrigger, budget: Double) async {
        guard !isRunning else { return }
        isRunning = true
        isChecking = true
        defer { isRunning = false; isChecking = false }
        let overall = Date().addingTimeInterval(budget)
        var checked = 0, found = 0, failed = 0
        for handle in handles {
            if Task.isCancelled || Date() > overall { break }
            // Leave room so the last account doesn't overrun a short background budget.
            let perAccount = min(overall, Date().addingTimeInterval(45))
            let result = await checkOne(handle, deadline: perAccount)
            if result.ok {
                checked += 1
                found += result.new
            } else {
                failed += 1
            }
        }
        lastCheckAt = Date()
        lastResult = "Checked \(checked), \(found) new" + (failed > 0 ? ", \(failed) couldn't be reached" : "")
        DebugLog.shared.add(.watch, "\(trigger.rawValue) check: \(lastResult ?? "")", level: failed > 0 ? .warning : .info)
        if wantsKeepAlive && watchdog { NotificationManager.shared.scheduleWatchdog(after: watchdogDelay) }
    }

    /// One account: reads its videos, stories and reposts tabs, notifies for anything new,
    /// and updates its seen keys. Returns how many new items, and whether it could be checked.
    private func checkOne(_ handle: String, deadline: Date) async -> (new: Int, ok: Bool) {
        guard watched.firstIndex(where: { $0.id == handle.lowercased() }) != nil else { return (0, false) }
        let started = Date()
        let engine = ProfileEngine(route: Route(query: handle, handle: handle), headless: true)
        engine.start()
        guard await waitUntilReady(engine, until: deadline), let header = engine.header else {
            engine.teardown()
            DebugLog.shared.warn(.watch, "Couldn't reach @\(handle) in \(Self.ms(started)) ms")
            return (0, false)
        }

        var current: [Activity: [String]] = [:]
        for activity in Activity.allCases {
            if Task.isCancelled || Date() > deadline { break }
            await engine.load(activity.tab)
            let items = engine.tabs[activity.tab]?.items ?? []
            current[activity] = items.prefix(24).map { StableKey.of($0, tab: activity.tab) }
        }
        engine.teardown()

        guard let index = watched.firstIndex(where: { $0.id == handle.lowercased() }) else { return (0, false) }
        var entry = watched[index]
        let firstTime = !entry.baselined
        var totalNew = 0
        for (activity, keys) in current {
            let seen = Set(entry.seen(activity))
            let fresh = keys.filter { !seen.contains($0) }
            if !firstTime && !fresh.isEmpty {
                totalNew += fresh.count
                NotificationManager.shared.notify(handle: entry.handle, name: entry.name,
                                                  activity: activity, count: fresh.count, timeSensitive: timeSensitive)
            }
            // Keep newest keys first, capped, so items don't re-notify and the list stays small.
            var merged = keys
            for key in entry.seen(activity) where !merged.contains(key) { merged.append(key) }
            entry.setSeen(activity, Array(merged.prefix(seenCap)))
        }
        entry.baselined = true
        entry.lastChecked = Date()
        if !header.name.isEmpty { entry.name = header.name }
        watched[index] = entry
        persistWatched()
        DebugLog.shared.add(.watch, "Checked @\(handle): \(totalNew) new\(firstTime ? " (baseline)" : ""), \(Self.ms(started)) ms")
        return (totalNew, true)
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

    private static func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    // MARK: Persistence

    private func persistWatched() { Store.save(watched, key: watchedKey) }
    private func persistEnabled() { UserDefaults.standard.set(enabled, forKey: enabledKey) }
    private func persistMode() { UserDefaults.standard.set(mode.rawValue, forKey: modeKey) }
}
