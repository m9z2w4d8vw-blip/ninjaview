import Foundation
import UIKit

/// The exported debug report: a snapshot of the app and phone, then the log of this
/// launch and the four before it.
@MainActor
enum Diagnostics {
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
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NinjaView-debug-\(stamp.string(from: Date())).txt")
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
        lines.append("Memory in use: \(memoryFootprint.map { String(format: "%.0f MB", $0) } ?? "unknown")")
        lines.append("Thermal state: \(thermal(process.thermalState)), Low Power Mode \(onOff(process.isLowPowerModeEnabled))")
        lines.append("Free space: \(freeSpace)")
        lines.append("Session copy: \(bytes(ProfileStore.size(of: ProfileStore.session.root)))")
        lines.append("Archives: \(ProfileStore.archive.profiles.count), \(bytes(ProfileStore.size(of: ProfileStore.archive.root)))")
        for profile in ProfileStore.archive.profiles.values.sorted(by: { $0.handle < $1.handle }) {
            lines.append("  @\(profile.handle): \(profile.status.rawValue), \(profile.savedPostCount) posts, \(bytes(profile.bytes)), updated \(profile.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        lines.append("Settings: appearance \(settings.appearance.rawValue), history \(onOff(settings.keepHistory)), ad blocking \(onOff(settings.blockAds)), tidy page \(onOff(settings.cleanLayout)), offline copies \(onOff(settings.prefetch)), comments \(onOff(settings.saveComments)), follower lists \(onOff(settings.saveLists))")
        lines.append("Open: \(EngineRegistry.shared.count) profile pages, \(FeedRegistry.shared.count) post lists, \(IGRegistry.shared.count) Instagram pages")
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
        lines.append("Line format: time, level, area, message. Areas: \(DebugLog.Category.allCases.map(\.rawValue).joined(separator: ", "))")
        return lines.joined(separator: "\n") + "\n"
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
