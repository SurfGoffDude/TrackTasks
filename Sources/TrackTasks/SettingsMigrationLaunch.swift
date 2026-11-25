import AppKit
import TrackTasksCore

/// Entry point. Before `TrackTasksApp`: its stored properties already read the settings and create the queue.
@main
enum Main {
    @MainActor static func main() {
        // `swift run` and tests have their own settings domain.
        guard Bundle.main.bundleIdentifier == SettingsMigration.currentID else { return TrackTasksApp.main() }
        let previous = NSRunningApplication.runningApplications(withBundleIdentifier: SettingsMigration.legacyID)
        if let error = SettingsMigration.launch(domains: UserDefaultsDomains(), previousIsRunning: !previous.isEmpty,
                                                start: { TrackTasksApp.main() }) {
            show(error)
        }
    }

    /// Nothing else is running at this point. A retry is a new process, so SwiftUI always starts clean.
    @MainActor private static func show(_ error: Error) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "TrackTasks не запущен: настройки не перенесены"
        alert.informativeText = error.localizedDescription + "\n\nПрежние настройки не изменены, очередь не запущена."
        alert.addButton(withTitle: "Повторить")
        alert.addButton(withTitle: "Выйти")
        if alert.runModal() == .alertFirstButtonReturn {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", Bundle.main.bundlePath]
            try? open.run()
            open.waitUntilExit()
        }
        exit(0)
    }
}
