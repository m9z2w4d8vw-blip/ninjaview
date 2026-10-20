import Foundation
import UIKit

/// Everything worth knowing when something breaks: page loads and every call into the
/// engine script with its timing, each request tik.ninja's page makes, script errors and
/// console warnings, downloads, playback, storage and app lifecycle.
///
/// Entries stay in memory for the in-app viewer and are appended to a file per launch in
/// Caches/Logs (the last five launches are kept), so a crash or force-quit doesn't lose them.
@MainActor
final class DebugLog: ObservableObject {
    enum Level: String, CaseIterable {
        case info, warning, error

        var tag: String {
            switch self {
            case .info: return "INFO "
            case .warning: return "WARN "
            case .error: return "ERROR"
            }
        }
    }

    enum Category: String, CaseIterable {
        case app, nav, web, js, net, crawl, download, player, image, store
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let category: Category
        let message: String
    }

    static let shared = DebugLog()
    /// Launches whose logs are kept on disk, this one included.
    static let keptLaunches = 5

    @Published private(set) var entries: [Entry] = []
    let launchDate: Date
    let folder: URL
    let sessionFile: URL

    private var pending: [Entry] = []
    private var flushScheduled = false
    private let memoryLimit = 5000
    private var fileHandle: FileHandle?
    private let lineFormatter = DateFormatter()

    private init() {
        let now = Date()
        let fm = FileManager.default
        let logs = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        launchDate = now
        folder = logs
        sessionFile = logs.appendingPathComponent("launch-\(stamp.string(from: now)).txt")
        lineFormatter.locale = Locale(identifier: "en_US_POSIX")
        lineFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        _ = fm.createFile(atPath: sessionFile.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: sessionFile)
        pruneOldLaunches()
    }

    /// Buffered and published on the next main-actor turn, so logging from inside a
    /// SwiftUI update never publishes in the middle of that update.
    func add(_ category: Category, _ message: String, level: Level = .info) {
        pending.append(Entry(date: Date(), level: level, category: category, message: message))
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in self?.flush() }
    }

    func warn(_ category: Category, _ message: String) { add(category, message, level: .warning) }

    func error(_ category: Category, _ message: String) { add(category, message, level: .error) }

    func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        entries.append(contentsOf: batch)
        if entries.count > memoryLimit { entries.removeFirst(entries.count - memoryLimit) }
        let text = batch.map(line(for:)).joined(separator: "\n") + "\n"
        if let data = text.data(using: .utf8) {
            _ = try? fileHandle?.seekToEnd()
            try? fileHandle?.write(contentsOf: data)
        }
    }

    /// One line of the .txt: time, level, area, message.
    func line(for entry: Entry) -> String {
        let area = entry.category.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
        return "\(lineFormatter.string(from: entry.date))  \(entry.level.tag)  \(area)\(entry.message)"
    }

    /// This launch's log file, plus the earlier launches' when asked, oldest first.
    func launchFiles(includePrevious: Bool) -> [URL] {
        flush()
        guard includePrevious else { return [sessionFile] }
        return allLaunchFiles()
    }

    func clear() {
        entries.removeAll()
        pending.removeAll()
        try? fileHandle?.truncate(atOffset: 0)
        for file in allLaunchFiles() where file != sessionFile {
            try? FileManager.default.removeItem(at: file)
        }
        add(.app, "Debug log cleared")
    }

    private func allLaunchFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("launch-") && $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pruneOldLaunches() {
        let files = allLaunchFiles()
        guard files.count > Self.keptLaunches else { return }
        for file in files.prefix(files.count - Self.keptLaunches) where file != sessionFile {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension Bundle {
    var versionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
