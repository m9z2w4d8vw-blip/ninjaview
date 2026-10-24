import Foundation

/// One allowance for every request the app sends to tik.ninja's API, shared by every hidden page.
/// Cloudflare refuses this connection from about 8 calls in 10 seconds or 16 in a minute, so the app
/// stays under that: whatever is on screen may use up to 5 calls in 10 seconds and 12 a minute,
/// notification checks a little less, and background copies less again, so they always leave room
/// for what you're looking at. Whatever is on screen goes first. A refusal (429) holds every page for
/// as long as tik.ninja asks, and three refused sessions (403) in a minute hold them for 45 seconds.
@MainActor
final class TikGate {
    static let shared = TikGate()

    enum Priority: Int, Comparable {
        case background = 0
        case watch = 1
        case foreground = 2

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

        var name: String {
            switch self {
            case .background: return "background"
            case .watch: return "notification check"
            case .foreground: return "on screen"
            }
        }

        /// How many calls in any 10 seconds, and in any minute, this priority may go up to.
        var limits: (burst: Int, minute: Int) {
            switch self {
            case .foreground: return (5, 12)
            case .watch: return (4, 10)
            case .background: return (3, 8)
            }
        }
    }

    private final class Ticket {
        let priority: Priority
        let since = Date()
        init(_ priority: Priority) { self.priority = priority }
    }

    private var waiting: [Ticket] = []
    private var grants: [Date] = []
    private var forbidden: [Date] = []
    /// No page asks tik.ninja anything before this.
    private(set) var holdUntil: Date?
    private var holdReason = ""

    private init() {}

    /// Waits until a call at this priority fits the allowance, then counts it.
    func acquire(_ priority: Priority, for label: String) async {
        let ticket = Ticket(priority)
        waiting.append(ticket)
        defer { waiting.removeAll { $0 === ticket } }
        var told = false
        while !Task.isCancelled {
            if allows(ticket) {
                grants.append(Date())
                if grants.count > 300 { grants.removeFirst(grants.count - 300) }
                if told { DebugLog.shared.add(.traffic, "[\(label)] Went ahead after waiting \(PageBridge.ago(ticket.since))") }
                return
            }
            if !told && Date().timeIntervalSince(ticket.since) >= 2 {
                told = true
                DebugLog.shared.add(.traffic, "[\(label)] Waiting its turn (\(priority.name)): \(waitDescription)")
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Whether a call at this priority would have to wait right now.
    func wouldWait(_ priority: Priority) -> Bool { !allows(Ticket(priority)) }

    private func allows(_ ticket: Ticket) -> Bool {
        let now = Date()
        if let holdUntil, holdUntil > now { return false }
        // Anything more important, or as important and waiting longer, goes first.
        let ahead = waiting.contains { other in
            other !== ticket && (other.priority > ticket.priority || (other.priority == ticket.priority && other.since < ticket.since))
        }
        if ahead { return false }
        let limits = ticket.priority.limits
        return used(within: 10, now: now) < limits.burst && used(within: 60, now: now) < limits.minute
    }

    /// Calls in the last `seconds`: the larger of those let through here and those the request log saw
    /// (which also catches requests tik.ninja's page made on its own).
    private func used(within seconds: TimeInterval, now: Date) -> Int {
        let granted = grants.reversed().prefix(while: { now.timeIntervalSince($0) < seconds }).count
        return max(granted, NetLedger.shared.apiCalls(within: seconds))
    }

    /// tik.ninja refused a request (HTTP 429): every page holds for as long as it asked.
    func refused(retryAfter: Int) {
        let wait = Double(min(60, max(10, retryAfter))) + Double.random(in: 0...2)
        hold(for: wait, "tik.ninja refused a request (HTTP 429)")
    }

    /// tik.ninja refused a session (HTTP 403). Three in a minute means it's refusing this connection for now.
    func refusedSession() {
        let now = Date()
        forbidden = forbidden.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard forbidden.count >= 3 else { return }
        forbidden.removeAll()
        hold(for: 45, "tik.ninja refused three sessions in a minute (HTTP 403)")
    }

    private func hold(for seconds: TimeInterval, _ reason: String) {
        let until = Date().addingTimeInterval(seconds)
        guard until > (holdUntil ?? .distantPast) else { return }
        holdUntil = until
        holdReason = reason
        DebugLog.shared.warn(.traffic, "\(reason); every page holds its requests until \(Diagnostics.clock(until))")
    }

    /// Why a call is waiting, for the log.
    var waitDescription: String {
        let now = Date()
        if let holdUntil, holdUntil > now {
            return "\(holdReason); continuing in \(Int(holdUntil.timeIntervalSince(now).rounded(.up))) s"
        }
        return "keeping under tik.ninja's limit (\(used(within: 10, now: now)) calls in the last 10 s, \(used(within: 60, now: now)) in the last minute)"
    }

    /// Why a profile on screen is waiting, in plain words.
    var userMessage: String {
        let now = Date()
        if let holdUntil, holdUntil > now {
            return "tik.ninja asked NinjaView to wait; continuing in \(Int(holdUntil.timeIntervalSince(now).rounded(.up))) s."
        }
        return "Waiting a moment to stay under tik.ninja's limit."
    }

    /// One line for reports.
    var summary: String {
        let now = Date()
        var line = "request allowance: \(used(within: 10, now: now)) of 5 used in the last 10 s, \(used(within: 60, now: now)) of 12 in the last minute"
        if let holdUntil, holdUntil > now { line += "; holding until \(Diagnostics.clock(holdUntil)) (\(holdReason))" }
        if !waiting.isEmpty { line += "; \(waiting.count) waiting" }
        return line
    }
}
