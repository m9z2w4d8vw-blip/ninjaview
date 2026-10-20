import Foundation
import UIKit

@MainActor
final class DebugLog: ObservableObject {
    enum Category: String {
        case app, web, js, net, nav, download
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let category: Category
        let message: String
    }

    static let shared = DebugLog()

    @Published private(set) var entries: [Entry] = []
    private var pending: [Entry] = []
    private var flushScheduled = false
    private let limit = 2000

    /// Buffered and published on the next main-actor turn, so logging from inside
    /// a SwiftUI update never publishes in the middle of that update.
    func add(_ category: Category, _ message: String) {
        pending.append(Entry(date: Date(), category: category, message: message))
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        entries.append(contentsOf: pending)
        pending.removeAll()
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func clear() {
        entries.removeAll()
        pending.removeAll()
    }

    func export() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header = "NinjaView \(Bundle.main.versionString), iOS \(UIDevice.current.systemVersion)\n"
        return header + entries
            .map { "\(formatter.string(from: $0.date)) [\($0.category.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }
}

extension Bundle {
    var versionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
