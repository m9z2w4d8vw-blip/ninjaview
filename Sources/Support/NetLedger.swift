import Foundation

/// Every request that reaches tik.ninja — from each hidden page (its fetches, the images it shows,
/// the page loads themselves) and from the app (thumbnails, saved media, avatars, the video
/// player) — kept in memory so a refusal (HTTP 429) can be explained: who was asking, how often,
/// and for what. All the hidden pages and the app share one connection, so tik.ninja's limit
/// counts them together.
///
/// It writes to the debug log's `traffic` area: a line a minute while there's traffic, and a full
/// report the moment tik.ninja refuses something.
@MainActor
final class NetLedger {
    static let shared = NetLedger()

    struct Event {
        let date: Date
        /// Who sent it: "P3 screen @name", "P5 session copy @name", "app images".
        let source: String
        /// fetch, xhr, img, script, page (a page load), native (the app's own request), …
        let kind: String
        let method: String
        let host: String
        /// The path with long ids collapsed to *, so one endpoint counts as one.
        let endpoint: String
        /// nil when NinjaView can't see the answer (images the page shows, the video player).
        let status: Int?
        let ms: Int?
    }

    struct Count {
        let key: String
        let count: Int
    }

    private(set) var events: [Event] = []
    private let cap = 8000
    let launched = Date()
    private(set) var total = 0
    private(set) var refusedTotal = 0
    private(set) var firstRefusal: Date?
    private(set) var lastRefusal: Date?
    private(set) var lastRetryAfter: String?
    /// The latest refused request in full (status line, headers, the start of the answer).
    private(set) var lastRefusalDetail: String?
    private var lastReportAt = Date.distantPast
    private var ticker: Task<Void, Never>?

    private init() {}

    /// Starts the once-a-minute summary.
    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.logLastMinute()
            }
        }
    }

    // MARK: Recording

    func record(source: String, kind: String, method: String, url: URL?, status: Int?, ms: Int?,
                retryAfter: String? = nil, detail: String? = nil) {
        guard let url, let host = url.host else { return }
        record(source: source, kind: kind, method: method, host: host, path: url.path, status: status, ms: ms,
               retryAfter: retryAfter, detail: detail)
    }

    /// Anything not on tik.ninja is ignored. `detail` is the refused request in full, when known.
    func record(source: String, kind: String, method: String, host: String, path: String, status: Int?, ms: Int?,
                retryAfter: String? = nil, detail: String? = nil) {
        let bare = Self.bareHost(host)
        guard Self.isTikNinja(bare) else { return }
        let event = Event(date: Date(), source: source, kind: kind, method: method.uppercased(), host: bare,
                          endpoint: Self.endpoint(path), status: status, ms: ms)
        events.append(event)
        if events.count > cap + 500 { events.removeFirst(events.count - cap) }
        total += 1
        guard status == 429 else { return }
        refusedTotal += 1
        if firstRefusal == nil { firstRefusal = event.date }
        lastRefusal = event.date
        if let retryAfter, !retryAfter.isEmpty { lastRetryAfter = retryAfter }
        if let detail, !detail.isEmpty { lastRefusalDetail = detail }
        // One full report per burst of refusals; the minute lines count the rest.
        guard event.date.timeIntervalSince(lastReportAt) > 20 else { return }
        lastReportAt = event.date
        DebugLog.shared.error(.traffic, refusalReport(event, retryAfter: retryAfter, detail: detail))
    }

    // MARK: Reading

    /// The events in the `seconds` up to `end`, oldest first.
    func window(_ seconds: TimeInterval, before end: Date = Date()) -> [Event] {
        let start = end.addingTimeInterval(-seconds)
        var slice: [Event] = []
        for event in events.reversed() {
            if event.date < start { break }
            if event.date <= end { slice.append(event) }
        }
        return Array(slice.reversed())
    }

    /// "143 requests (2.4 a second), 3 refused with 429", then who sent them, what they asked for
    /// and what came back.
    func describe(_ slice: [Event], seconds: TimeInterval) -> [String] {
        guard !slice.isEmpty else { return ["no requests"] }
        let refused = slice.filter { $0.status == 429 }.count
        let otherErrors = slice.filter { ($0.status ?? 0) >= 400 && $0.status != 429 }.count
        let unanswered = slice.filter { $0.status == 0 }.count
        let rate = String(format: "%.1f", Double(slice.count) / max(1, seconds))
        var head = "\(slice.count) requests (\(rate) a second)"
        head += refused > 0 ? ", \(refused) refused with 429" : ", none refused"
        if otherErrors > 0 { head += ", \(otherErrors) other errors" }
        if unanswered > 0 { head += ", \(unanswered) without an answer" }
        let statuses = slice.map { event -> String in
            guard let status = event.status else { return "unseen" }
            return String(status)
        }
        return [head,
                "by source: " + Self.tally(slice.map(\.source)),
                "by request: " + Self.tally(slice.map { "\($0.kind) \($0.method) \($0.endpoint)" }, limit: 8),
                "by status: " + Self.tally(statuses, limit: 8)]
    }

    /// The last minute and the last five, for failure reports and the exported report.
    func recentLines() -> [String] {
        var lines: [String] = []
        for (label, seconds) in [("last 60 s", 60.0), ("last 5 min", 300.0)] {
            let described = describe(window(seconds), seconds: seconds)
            lines.append("\(label): " + described[0])
            lines.append(contentsOf: described.dropFirst().map { "  " + $0 })
        }
        lines.append(launchLine())
        return lines
    }

    func launchLine() -> String {
        var line = "since launch (\(Diagnostics.duration(Date().timeIntervalSince(launched)))): \(total) requests, \(refusedTotal) refused with 429"
        if let firstRefusal, let lastRefusal {
            line += " (first \(Diagnostics.clock(firstRefusal)), last \(Diagnostics.clock(lastRefusal)))"
        }
        if let lastRetryAfter { line += ", last Retry-After \(lastRetryAfter)" }
        return line
    }

    /// A few short lines for the top of the in-app debug log.
    func liveLines() -> [String] {
        let minute = window(60)
        let refused = minute.filter { $0.status == 429 }.count
        var lines = ["last 60 s: \(minute.count) requests, \(refused) refused"]
        if !minute.isEmpty { lines.append("from " + Self.tally(minute.map(\.source), limit: 4)) }
        lines.append(launchLine())
        return lines
    }

    /// One line per minute that had traffic, for the exported report.
    func timeline(minutes: Int) -> [String] {
        let start = Date().addingTimeInterval(-Double(minutes) * 60)
        var buckets: [Int: [Event]] = [:]
        for event in events where event.date >= start {
            buckets[Int(event.date.timeIntervalSince1970 / 60), default: []].append(event)
        }
        guard !buckets.isEmpty else { return ["no tik.ninja requests in the last \(minutes) minutes"] }
        return buckets.keys.sorted().map { minute -> String in
            let slice = buckets[minute] ?? []
            let refused = slice.filter { $0.status == 429 }.count
            var line = "\(Diagnostics.minute(Date(timeIntervalSince1970: Double(minute) * 60)))  \(slice.count) requests"
            if refused > 0 { line += ", \(refused) refused" }
            return line + "  (" + Self.tally(slice.map(\.source), limit: 3) + ")"
        }
    }

    // MARK: Logging

    private func logLastMinute() {
        let slice = window(60)
        guard !slice.isEmpty else { return }
        let refused = slice.contains { $0.status == 429 }
        DebugLog.shared.add(.traffic, "tik.ninja traffic, last 60 s: " + describe(slice, seconds: 60).joined(separator: "\n  "),
                            level: refused ? .warning : .info)
    }

    private func refusalReport(_ event: Event, retryAfter: String?, detail: String?) -> String {
        var lines = ["tik.ninja refused a request with HTTP 429 (\(refusedTotal) refused this launch"
                     + (firstRefusal.map { ", the first at \(Diagnostics.clock($0))" } ?? "") + ")"]
        var refused = "refused: \(event.kind) \(event.method) \(event.host)\(event.endpoint) from \(event.source)"
        if let ms = event.ms { refused += ", answered in \(ms) ms" }
        lines.append(refused)
        if let retryAfter, !retryAfter.isEmpty { lines.append("Retry-After: \(retryAfter) (how long tik.ninja asks clients to wait)") }
        if let detail, !detail.isEmpty {
            lines.append("what was sent and what came back:")
            lines.append(contentsOf: detail.components(separatedBy: "\n").map { "  " + $0 })
        }
        for (label, seconds) in [("10 s", 10.0), ("60 s", 60.0), ("5 min", 300.0)] {
            let described = describe(window(seconds, before: event.date), seconds: seconds)
            lines.append("in the \(label) up to it: " + described[0])
            lines.append(contentsOf: described.dropFirst().map { "  " + $0 })
        }
        lines.append(launchLine())
        lines.append("running right now:")
        lines.append(contentsOf: Diagnostics.activityLines().map { "  " + $0 })
        lines.append("network: \(NetworkStatus.shared.summary)")
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    nonisolated static func isTikNinja(_ host: String) -> Bool {
        host == "tik.ninja" || host.hasSuffix(".tik.ninja")
    }

    /// Lower-cased, without a port.
    nonisolated static func bareHost(_ host: String) -> String {
        let lower = host.lowercased()
        guard let colon = lower.firstIndex(of: ":") else { return lower }
        return String(lower[..<colon])
    }

    /// "/api/user/7234567890123/videos" becomes "/api/user/*/videos".
    nonisolated static func endpoint(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            let segment = String(part)
            if segment.count >= 6 && segment.allSatisfy({ $0.isNumber }) { return "*" }
            if segment.count >= 24 { return "*" }
            return segment
        }
        let joined = parts.joined(separator: "/")
        let shown = joined.isEmpty ? "/" : joined
        return shown.count > 80 ? String(shown.prefix(80)) + "\u{2026}" : shown
    }

    nonisolated static func counts(_ values: [String]) -> [Count] {
        var tally: [String: Int] = [:]
        for value in values { tally[value, default: 0] += 1 }
        return tally.map { Count(key: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }

    /// "P5 session copy @a 120 · app images 11 · +2 more"
    nonisolated static func tally(_ values: [String], limit: Int = 6) -> String {
        let sorted = counts(values)
        guard !sorted.isEmpty else { return "none" }
        var parts = sorted.prefix(limit).map { "\($0.key) \($0.count)" }
        if sorted.count > limit { parts.append("+\(sorted.count - limit) more") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// Short descriptions of the app's own HTTP answers for the debug log.
enum HTTPDebug {
    /// Headers that explain a refusal and where an answer came from.
    static let notable = ["Retry-After", "X-RateLimit-Limit", "X-RateLimit-Remaining", "X-RateLimit-Reset",
                          "RateLimit-Limit", "RateLimit-Remaining", "RateLimit-Reset", "RateLimit-Policy",
                          "CF-Mitigated", "Server", "CF-RAY", "CF-Cache-Status", "Content-Type", "Content-Length",
                          "Location", "Age", "Via", "X-Cache"]

    /// "429 too many requests · retry-after 60 · server cloudflare · cf-ray 8f…"
    static func describe(_ http: HTTPURLResponse) -> String {
        var parts = ["\(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"]
        for name in notable {
            if let value = http.value(forHTTPHeaderField: name), !value.isEmpty {
                parts.append("\(name.lowercased()) \(value.prefix(160))")
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func retryAfter(_ response: URLResponse?) -> String? {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
    }

    /// Whether the answer is worth quoting (text, JSON, HTML) rather than an image or a video.
    static func isTextual(_ http: HTTPURLResponse) -> Bool {
        guard let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() else { return true }
        return ["json", "text", "html", "xml"].contains { type.contains($0) }
    }

    /// The start of an answer, on one line.
    static func snippet(_ data: Data, limit: Int = 600) -> String {
        let text = String(decoding: data.prefix(limit * 4), as: UTF8.self)
        let squashed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return squashed.count > limit ? String(squashed.prefix(limit)) + "\u{2026}" : squashed
    }

    static func snippet(file: URL, limit: Int = 600) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit * 4)) ?? Data()
        return snippet(data, limit: limit)
    }
}
