import Foundation
import UIKit
import WebKit

/// The exported debug report — a snapshot of the app, phone and connection, a summary of tik.ninja
/// traffic and the latest lookup failure, then the log of this launch and the four before it —
/// and the pieces failure reports are built from.
@MainActor
enum Diagnostics {
    /// The newest failure report from any profile page.
    static var lastFailureReport: String?

    static func exportReport(includePrevious: Bool = true) -> URL? {
        let log = DebugLog.shared
        log.add(.app, "Exporting a debug report")
        var text = header()
        for file in log.launchFiles(includePrevious: includePrevious) {
            let body = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let label = file == log.sessionFile ? "This launch" : "Earlier launch"
            text += "\n===== \(label): \(file.lastPathComponent) =====\n"
            text += body.isEmpty ? "(nothing logged)\n" : body
        }
        let fileStamp = DateFormatter()
        fileStamp.locale = Locale(identifier: "en_US_POSIX")
        fileStamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NinjaView-debug-\(fileStamp.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            log.error(.app, "Couldn't write the debug report: \(error.localizedDescription)")
            return nil
        }
    }

    static func header() -> String {
        let settings = AppSettings.shared
        let device = UIDevice.current
        let process = ProcessInfo.processInfo
        let launched = DebugLog.shared.launchDate
        var lines = ["NinjaView debug report"]
        lines.append("Created: \(Date().formatted(date: .complete, time: .standard))")
        lines.append("App: \(Bundle.main.versionString), \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("Device: \(modelIdentifier), \(device.systemName) \(device.systemVersion)")
        lines.append("Locale: \(Locale.current.identifier), time zone \(TimeZone.current.identifier)")
        lines.append("Launched: \(launched.formatted(date: .abbreviated, time: .standard)), running for \(Int(Date().timeIntervalSince(launched))) s")
        lines.append("Network: \(NetworkStatus.shared.summary)")
        lines.append("Memory in use: \(memoryFootprint.map { String(format: "%.0f MB", $0) } ?? "unknown")")
        lines.append("Thermal state: \(thermal(process.thermalState)), Low Power Mode \(onOff(process.isLowPowerModeEnabled))")
        lines.append("Free space: \(freeSpace)")
        lines.append("Session copy: \(bytes(ProfileStore.size(of: ProfileStore.session.root)))")
        lines.append("Archives: \(ProfileStore.archive.profiles.count), \(bytes(ProfileStore.size(of: ProfileStore.archive.root)))")
        for profile in ProfileStore.archive.profiles.values.sorted(by: { $0.handle < $1.handle }) {
            lines.append("  @\(profile.handle): \(profile.status.rawValue), \(profile.savedPostCount) posts, \(bytes(profile.bytes)), updated \(profile.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        lines.append("Settings: appearance \(settings.appearance.rawValue), history \(onOff(settings.keepHistory)), ad blocking \(onOff(settings.blockAds)), tidy page \(onOff(settings.cleanLayout)), offline copies \(onOff(settings.prefetch)), comments \(onOff(settings.saveComments)), follower lists \(onOff(settings.saveLists)), verbose network log \(onOff(settings.verboseNetLog))")
        lines.append("Open: \(EngineRegistry.shared.count) profile pages, \(FeedRegistry.shared.count) post lists, \(IGRegistry.shared.count) Instagram pages")
        lines.append("Hidden pages: \(pageList())")
        let igArchives = IGArchive.shared.sortedAccounts
        lines.append("Instagram archives: \(igArchives.count)")
        for account in igArchives {
            lines.append("  @\(account.handle): \(account.stories.count) stories, \(account.posts.count) posts, \(bytes(IGArchive.shared.size(account.handle)))\(account.note.isEmpty ? "" : ", note: " + account.note)")
        }
        let watch = WatchCenter.shared
        lines.append("Watching: \(watch.count) accounts, notifications \(onOff(watch.enabled)), \(watch.mode.rawValue) mode, every \(Int(watch.pollInterval))s, keeping awake: \(watch.keepAwakeStatus.lowercased()), watchdog \(onOff(watch.watchdog)), time-sensitive \(onOff(watch.timeSensitive))")
        for entry in watch.watched {
            let checked = entry.lastChecked?.formatted(date: .abbreviated, time: .shortened) ?? "never"
            lines.append("  \(entry.label): \(Activity.list(entry.activities).lowercased()); first look done for \(Activity.list(entry.baselined).lowercased()); last checked \(checked)")
        }
        if let until = watch.restingUntil, until > Date() {
            lines.append("  Automatic checks paused until \(until.formatted(date: .omitted, time: .shortened)) (tik.ninja rate limit)")
        }
        let crawls = CrawlCenter.shared.crawls.values
            .sorted { $0.id < $1.id }
            .map { "\($0.mode.rawValue) @\($0.handle) \(describe($0.state)) \($0.postsDone)/\($0.postsTotal)" }
        lines.append("Downloads: \(crawls.isEmpty ? "none" : crawls.joined(separator: "; "))")
        lines.append("")
        lines.append("tik.ninja traffic (every hidden page plus the app's own image, video and download requests):")
        lines.append(contentsOf: NetLedger.shared.recentLines().map { "  " + $0 })
        lines.append("  minute by minute, last 60 minutes:")
        lines.append(contentsOf: NetLedger.shared.timeline(minutes: 60).map { "    " + $0 })
        if let report = lastFailureReport {
            lines.append("")
            lines.append("Latest lookup failure (it's in the log below too):")
            lines.append(contentsOf: report.components(separatedBy: "\n").map { "  " + $0 })
        }
        lines.append("")
        lines.append("Line format: time, level, area, message. Lines from a hidden page start with its name, like [P3 screen @name]. Areas: \(DebugLog.Category.allCases.map(\.rawValue).joined(separator: ", "))")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Pieces of failure reports

    /// "3: P2 session copy @a (ready), P3 screen @b (not ready), P4 spare (preloaded, unclaimed)"
    static func pageList() -> String {
        var pages = PageBridge.openPages.map { "\($0.label) (\($0.isReady ? "ready" : "not ready"))" }
        if let spare = WebFactory.shared.spareTag { pages.append("\(spare) spare (preloaded, unclaimed)") }
        return pages.isEmpty ? "none" : "\(pages.count): " + pages.joined(separator: ", ")
    }

    /// What's using tik.ninja right now: hidden pages, downloads and the notification checks.
    static func activityLines() -> [String] {
        var lines = ["hidden pages: " + pageList()]
        let center = CrawlCenter.shared
        if let current = center.current {
            let doing = current.activity.isEmpty ? "starting" : current.activity
            lines.append("download running: \(current.mode.rawValue) copy of @\(current.handle), \(doing) (\(current.postsDone) of \(current.postsTotal) posts)")
        } else {
            lines.append("download running: none")
        }
        let queued = center.crawls.values
            .filter { $0.state == .queued && $0 !== center.current }
            .map { "\($0.mode.rawValue) @\($0.handle)" }
            .sorted()
        if !queued.isEmpty { lines.append("downloads waiting their turn: " + queued.joined(separator: ", ")) }
        let watch = WatchCenter.shared
        var watching = "notification checks: \(onOff(watch.enabled)), \(watch.count) accounts, \(watch.mode.rawValue) mode, every \(Int(watch.pollInterval)) s"
        watching += watch.isChecking ? ", checking right now" : ", idle"
        if let last = watch.lastCheckAt { watching += ", last round \(PageBridge.ago(last)) ago" }
        if let until = watch.restingUntil, until > Date() {
            watching += ", resting until \(clock(until)) after \(watch.refusals) refused rounds in a row"
        }
        lines.append(watching)
        let settings = AppSettings.shared
        lines.append("offline settings: download profiles you open \(onOff(settings.prefetch)), comments \(onOff(settings.saveComments)), follower lists \(onOff(settings.saveLists))")
        return lines
    }

    /// tik.ninja's cookies by name, from the shared in-memory store (values are never shown).
    static func cookieLine() async -> String {
        let cookies = await WebFactory.shared.dataStore.httpCookieStore.allCookies()
        let mine = cookies.filter { cookie in
            NetLedger.isTikNinja(cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        guard !mine.isEmpty else { return "tik.ninja cookies: none" }
        let names = mine.map { cookie -> String in
            var flags: [String] = []
            if cookie.isHTTPOnly { flags.append("HttpOnly") }
            flags.append(cookie.expiresDate.map { "expires \(stamp($0))" } ?? "until NinjaView quits")
            return "\(cookie.name) (\(flags.joined(separator: ", ")))"
        }
        return "tik.ninja cookies (names only): " + names.joined(separator: "; ")
    }

    /// The page's answer to window.__nv.diagnose(), as report lines.
    static func describePage(_ p: [String: Any]) -> [String] {
        func text(_ key: String) -> String { (p[key] as? String) ?? "" }
        func flag(_ key: String) -> Bool { (p[key] as? Bool) ?? false }
        func list(_ key: String) -> [String] { (p[key] as? [Any])?.map { String(describing: $0) } ?? [] }

        var lines: [String] = []
        var top = (text("url").isEmpty ? "?" : text("url")) + " \u{00B7} title \"\(text("title"))\""
        if !text("readyState").isEmpty { top += " \u{00B7} \(text("readyState"))" }
        if !text("visibility").isEmpty { top += ", \(text("visibility"))" }
        if p["online"] != nil { top += flag("online") ? ", online" : ", OFFLINE" }
        if let since = PageBridge.number(p["sinceLoad"]) { top += " \u{00B7} \(since) ms since it began loading" }
        if let engine = PageBridge.number(p["engine"]) {
            top += engine > 0 ? " \u{00B7} engine v\(engine)" : " \u{00B7} the engine script isn't on this page"
        }
        lines.append(top)
        if let nav = p["navigation"] as? [String: Any] {
            var line = "page load: \(nav["type"] as? String ?? "?")"
            if let status = PageBridge.number(nav["status"]), status > 0 { line += ", HTTP \(status)" }
            if let ms = PageBridge.number(nav["ms"]) { line += ", \(ms) ms" }
            if let size = PageBridge.number(nav["size"]), size > 0 {
                line += ", " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            }
            lines.append(line)
        }
        if p["searchBox"] != nil {
            var line = "search box: " + (flag("searchBox") ? "present, holding \"\(text("searchValue"))\"" : "MISSING")
            line += " \u{00B7} Search button: " + (flag("searchButton") ? (flag("buttonDisabled") ? "disabled" : "enabled") : "MISSING")
            if !text("buttonText").isEmpty { line += " (\"\(text("buttonText"))\")" }
            lines.append(line)
        }
        if p["status"] != nil {
            var line = "status line: " + (text("status").isEmpty ? "(empty)" : "\"\(text("status"))\"")
            if !text("statusClass").isEmpty { line += " \u{00B7} class \"\(text("statusClass"))\"" }
            lines.append(line)
            if !text("statusHTML").isEmpty && text("statusHTML") != text("status") {
                lines.append("status line markup: \(text("statusHTML"))")
            }
        }
        if p["modal"] != nil {
            let profile = text("profile").isEmpty ? "none" : "@" + text("profile")
            lines.append("profile shown: \(profile) \u{00B7} post open: \(flag("modal") ? "yes" : "no") \u{00B7} comments open: \(flag("comments") ? "yes" : "no") \u{00B7} ad overlay: \(flag("vignette") ? "yes" : "no")")
        }
        if p["challenge"] != nil {
            let found = list("challenge")
            lines.append("verification or captcha elements: " + (found.isEmpty ? "none" : found.joined(separator: ", ")))
        }
        if p["cookies"] != nil {
            let found = list("cookies")
            lines.append("cookies the page can see (names): " + (found.isEmpty ? "none" : found.joined(separator: ", ")))
        }
        if p["storage"] != nil {
            let found = list("storage")
            lines.append("site storage keys: " + (found.isEmpty ? "none" : found.joined(separator: ", ")))
        }
        if !text("userAgent").isEmpty {
            var line = "browser: \(text("userAgent")) \u{00B7} \(text("language")) \u{00B7} \(text("viewport"))"
            if flag("webdriver") { line += " \u{00B7} navigator.webdriver is TRUE" }
            lines.append(line)
        }
        let errors = list("errors")
        if !errors.isEmpty {
            lines.append("script errors on the page:")
            lines.append(contentsOf: errors.map { "  " + $0 })
        }
        if p["net"] != nil {
            let net = list("net")
            lines.append(net.isEmpty ? "requests the page made: none seen" : "the page's latest requests (oldest first):")
            lines.append(contentsOf: net.map { "  " + $0 })
        }
        let waiting = list("waiting")
        if !waiting.isEmpty {
            lines.append("requests still waiting for an answer:")
            lines.append(contentsOf: waiting.map { "  " + $0 })
        }
        if !text("bodyText").isEmpty { lines.append("visible text: \(text("bodyText"))") }
        return lines
    }

    /// Plain readings of a failure, drawn only from what the report itself shows.
    static func hints(shown: String, trace: [String], pageLabel: String, attempts: Int) -> [String] {
        var out: [String] = []
        let lower = shown.lowercased()
        let answers = answerStatuses(trace)
        if lower.contains("get past the check") {
            out.append("There's no search box on the page, so tik.ninja is most likely showing a verification page (Cloudflare) or its layout changed. \"the page right after\" lists any verification elements and the page's visible text. Show page lets you get past a check.")
        }
        if lower.contains("didn't return this account in time") {
            out.append("Neither a profile nor an error appeared within 30 seconds. If \"requests still waiting\" lists something, tik.ninja's server never answered it; if the status line is empty, the click may not have started a search.")
        }
        if lower.contains("took too long") {
            out.append("NinjaView's call into the page didn't come back in time, so the page itself may be stuck or busy. The page state above shows what it was doing.")
        }
        let limited = lower.contains("429") || lower.contains("too many") || lower.contains("rate limit") || answers.contains(429)
        guard limited else { return out }
        out.append("HTTP 429 means \"too many requests\": a server is refusing requests from this connection for a while.")
        if answers.contains(429) {
            out.append("The 429 came straight from tik.ninja's server (or Cloudflare in front of it), so the limit applies to this connection or this session.")
        } else if !answers.isEmpty {
            let seen = Array(Set(answers)).sorted().map { String($0) }.joined(separator: ", ")
            out.append("tik.ninja's server itself answered \(seen), not 429, so the 429 in its message most likely came from further up: tik.ninja's own access to TikTok. That limits everyone who uses tik.ninja at once, and only waiting helps.")
        } else if !trace.isEmpty {
            out.append("The page showed the error without an answer NinjaView could see (it may have come from the browser's cache, or from a kind of request the logger doesn't catch).")
        }
        let ledger = NetLedger.shared
        if let detail = ledger.lastRefusalDetail?.lowercased(),
           detail.contains("1015") || (detail.contains("cloudflare") && detail.contains("rate limit")) {
            out.append("The refused answer looks like Cloudflare's rate limiting (error 1015), which counts requests per public IP address.")
        }
        let recent = ledger.window(300)
        if recent.count <= 15 {
            out.append("NinjaView sent only \(recent.count) requests to tik.ninja in the 5 minutes before this, so its own traffic probably isn't what used up the limit. Either tik.ninja is limiting everyone right now, or this connection's public address is shared with other people (campus or public Wi-Fi, a carrier's shared address, a VPN). Opening tik.ninja in Safari on the same connection tells them apart: if Safari is refused too, NinjaView isn't the cause. Switching between Wi-Fi and cellular changes the address.")
        } else {
            var line = "In the 5 minutes before this, NinjaView sent \(recent.count) requests to tik.ninja"
            if let top = NetLedger.counts(recent.map(\.source)).first {
                line += "; the most came from \(top.key) (\(top.count), \(percent(top.count, of: recent.count)))"
            }
            let own = recent.filter { $0.source == pageLabel }.count
            out.append(line + "; this page sent \(own).")
            let downloads = recent.filter { isDownload($0.source) }.count
            let checks = recent.filter { $0.source.contains("watch check") }.count
            if downloads + checks > 0 {
                out.append("Offline copies and archives sent \(downloads) of them (\(percent(downloads, of: recent.count))) and notification checks \(checks) (\(percent(checks, of: recent.count))). They share this connection with the profile you're opening, so they use up the same limit. To test that, turn off Settings > Offline > Download profiles you open, pause any archive, turn off notifications, wait 10 to 15 minutes, then try again.")
            }
        }
        if let retry = ledger.lastRetryAfter {
            out.append("tik.ninja asked clients to wait before trying again (Retry-After: \(retry)); trying sooner will most likely be refused too.")
        }
        if attempts > 1 {
            out.append("This was attempt \(attempts) on this screen. Each Try again reloads tik.ninja's page and searches again, and that counts against the limit too.")
        }
        return out
    }

    /// The statuses of tik.ninja's answers in a lookup trace ("← GET 429 tik.ninja/api/…").
    static func answerStatuses(_ trace: [String]) -> [Int] {
        trace.compactMap { line -> Int? in
            guard let range = line.range(of: "\u{2190} ") else { return nil }
            let words = line[range.upperBound...].split(separator: " ", maxSplits: 3).map(String.init)
            guard words.count >= 3 else { return nil }
            let host = String(words[2].split(separator: "/").first ?? "")
            guard NetLedger.isTikNinja(NetLedger.bareHost(host)) else { return nil }
            return Int(words[1])
        }
    }

    private static func isDownload(_ source: String) -> Bool {
        source.contains("session copy") || source.contains(" archive @") || source == "app media saves"
    }

    private static func percent(_ part: Int, of whole: Int) -> String {
        "\(Int((Double(part) / Double(max(1, whole)) * 100).rounded()))%"
    }

    // MARK: Formatting

    private static let clockFormatter = formatter("HH:mm:ss")
    private static let minuteFormatter = formatter("HH:mm")
    private static let stampFormatter = formatter("yyyy-MM-dd HH:mm:ss")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
    static func minute(_ date: Date) -> String { minuteFormatter.string(from: date) }
    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 120 { return "\(s) s" }
        if s < 7200 { return "\(s / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    private static func describe(_ state: Crawl.State) -> String {
        switch state {
        case .queued: return "queued"
        case .running: return "running"
        case .paused: return "paused"
        case .finished: return "finished"
        case .failed(let reason): return "failed (\(reason))"
        }
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    private static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    private static var freeSpace: String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return "unknown" }
        return bytes(capacity)
    }

    /// "iPhone14,5" and the like.
    nonisolated static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return Mirror(reflecting: info.machine).children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    /// The app's memory footprint in MB, as Xcode's gauge reports it.
    nonisolated static var memoryFootprint: Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    nonisolated static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
