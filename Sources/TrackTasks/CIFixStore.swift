import Foundation
import TrackTasksCore

/// Automatic «Исправить CI» by project. Not in about.md: a project's file can be changed by an agent.
@Observable @MainActor
final class CIFixStore {
    static let shared = CIFixStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TrackTasks/ci-fix.json"))

    private let url: URL
    private(set) var options: CIFixOptions

    init(url: URL) {
        self.url = url
        let r = CIFixOptions.load(url)
        options = r.options
        if let p = r.problem { StorageIssues.shared.report(p) }
    }

    func isOn(_ project: URL) -> Bool { options.isOn(project.path) }

    /// On only after the file is written; off at once.
    func set(_ project: URL, _ on: Bool) {
        var next = options
        next.set(project.path, on)
        do {
            try next.save(url)
            options = next
        } catch {
            if !on {
                options = next
                // An old file must not turn it on again after a restart.
                try? FileManager.default.removeItem(at: url)
            }
            StorageIssues.shared.report("Не удалось записать \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
