import AppKit
import UserNotifications

/// macOS notifications with actions: approve/deny a command, merge a branch, open the queue.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let enabledKey = "notifications"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    enum Action { case allow(String), deny(String), merge(UUID), open(UUID?) }
    var handler: ((Action) -> Void)?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes outside an app bundle (`swift run`, tests).
        Bundle.main.bundleURL.pathExtension != "app" ? nil : UNUserNotificationCenter.current()
    }

    func setup() {
        guard let center else { return }
        center.delegate = self
        let allow = UNNotificationAction(identifier: "allow", title: "Разрешить")
        let deny = UNNotificationAction(identifier: "deny", title: "Отклонить", options: [.destructive])
        let merge = UNNotificationAction(identifier: "merge", title: "Слить")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "permission", actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "mergeable", actions: [merge], intentIdentifiers: []),
            UNNotificationCategory(identifier: "plain", actions: [], intentIdentifiers: []),
        ])
    }

    func askPermission() {
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String, jobID: UUID? = nil, canMerge: Bool = false, id: String = UUID().uuidString) {
        guard Self.enabled, let center else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.categoryIdentifier = canMerge ? "mergeable" : "plain"
        if let jobID { c.userInfo["job"] = jobID.uuidString }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func permission(_ r: PermissionRequest, job: Job) {
        guard Self.enabled, let center, !NSApp.isActive else { return }
        let c = UNMutableNotificationContent()
        c.title = "Агент просит разрешение"
        c.subtitle = "\(job.projectName): \(job.title)"
        c.body = r.title
        c.sound = .default
        c.categoryIdentifier = "permission"
        c.userInfo = ["request": r.id, "job": job.id.uuidString]
        center.add(UNNotificationRequest(identifier: r.id, content: c, trigger: nil))
    }

    func clear(id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let request = info["request"] as? String
        let job = (info["job"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let h = Notifier.shared.handler
                switch action {
                case "allow": if let request { h?(.allow(request)) }
                case "deny": if let request { h?(.deny(request)) }
                case "merge": if let job { h?(.merge(job)) }
                default: h?(.open(job))
                }
            }
        }
        completionHandler()
    }
}
