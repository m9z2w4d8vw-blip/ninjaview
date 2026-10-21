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
enum BackgroundScheduler {
    static func register() {
        let refresh = BGTaskScheduler.shared.register(forTaskWithIdentifier: WatchTask.refreshID, using: DispatchQueue.main) { task in
            handle(task, trigger: .backgroundRefresh)
        }
        let processing = BGTaskScheduler.shared.register(forTaskWithIdentifier: WatchTask.processingID, using: DispatchQueue.main) { task in
            handle(task, trigger: .backgroundProcessing)
        }
        if !refresh || !processing {
            DebugLog.shared.error(.watch, "Background task registration failed")
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
            DebugLog.shared.warn(.watch, "Couldn't schedule \(request.identifier): \(error.localizedDescription). Background App Refresh may be off for NinjaView.")
        }
    }

    private static func handle(_ task: BGTask, trigger: CheckTrigger) {
        scheduleAll() // always line up the next one
        let completion = TaskCompletion(task)
        task.expirationHandler = {
            DebugLog.shared.warn(.watch, "iOS ended a background run early")
            completion.finish(false)
        }
        Task { @MainActor in
            let ok = await WatchCenter.shared.runBackgroundCheck(trigger: trigger)
            completion.finish(ok)
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
