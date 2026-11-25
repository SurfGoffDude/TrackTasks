import Foundation

/// Keeps the Mac awake while the queue works (running job or its verification).
/// Paused queue and waiting for the limit allow sleep. Closed lid still sleeps — the system decides that.
@MainActor
final class SleepGuard {
    static let shared = SleepGuard()
    static let enabledKey = "preventSleep"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private var activity: NSObjectProtocol?
    var isHeld: Bool { activity != nil }

    /// Call on every queue event; `busy` = something is running and the queue isn't paused.
    func update(busy: Bool) {
        let want = busy && Self.enabled
        if want, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled], reason: "TrackTasks: очередь выполняет задачи")
        } else if !want, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
}
