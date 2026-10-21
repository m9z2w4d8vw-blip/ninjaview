import BackgroundTasks
import Foundation

/// Which wakeup asked for a check.
enum CheckTrigger: String {
    case foreground = "Foreground"
    case instant = "Instant"
    case backgroundRefresh = "Background refresh"
    case backgroundProcessing = "Background processing"
    case manual = "Manual"
}

/// Background App Refresh and a longer processing task, kept scheduled as a backup to
/// Instant mode. iOS decides when (and whether) these actually run.
///
/// This type isn't on the main actor (iOS calls the launch handlers on the queue given at
/// registration), so its log lines hop over to the main actor, where DebugLog lives.
enum BackgroundScheduler {
    static func register() {
        // Registering an identifier that Info.plist doesn't list crashes the app, so check first.
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        let tasks: [(String, CheckTrigger)] = [(WatchTask.refreshID, .backgroundRefresh),
                                               (WatchTask.processingID, .backgroundProcessing)]
        var problems: [String] = []
        for (identifier, trigger) in tasks {
            guard permitted.contains(identifier) else {
                problems.append("\(identifier) isn't in Info.plist")
                continue
            }
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: DispatchQueue.main) { task in
                handle(task, trigger: trigger)
            }
            if !registered { problems.append("\(identifier) was refused") }
        }
        if !problems.isEmpty {
            log("Background task registration failed: " + problems.joined(separator: "; "), isError: true)
        }
    }

    static func scheduleAll() {
        let refresh = BGAppRefreshTaskRequest(identifier: WatchTask.refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: WatchTask.processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 45 * 60)
        submit(processing)
    }

    private static func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log("Couldn't schedule \(request.identifier): \(error.localizedDescription). Background App Refresh may be off for NinjaView.")
        }
    }

    private static func handle(_ task: BGTask, trigger: CheckTrigger) {
        scheduleAll() // always line up the next one
        let completion = TaskCompletion(task)
        let work = Task { @MainActor in
            let ok = await WatchCenter.shared.runBackgroundCheck(trigger: trigger)
            completion.finish(ok)
        }
        task.expirationHandler = {
            work.cancel() // the checks stop at their next cancellation point
            log("iOS ended a background run early")
            completion.finish(false)
        }
    }

    /// The message is built here; only the finished String crosses to the main actor.
    private static func log(_ message: String, isError: Bool = false) {
        Task { @MainActor in
            if isError {
                DebugLog.shared.error(.watch, message)
            } else {
                DebugLog.shared.warn(.watch, message)
            }
        }
    }
}

/// Completes a background task exactly once.
private final class TaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let task: BGTask

    init(_ task: BGTask) { self.task = task }

    func finish(_ success: Bool) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { task.setTaskCompleted(success: success) }
    }
}
