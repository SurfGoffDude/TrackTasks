import Foundation
import TrackTasksCore

/// Until the first-run screen is closed nothing starts an agent or goes to the network by itself.
/// Open from the start for everybody who isn't new.
@Observable @MainActor
final class LaunchGate {
    /// Touched first of all at launch: what is written later must not look like an old user's data.
    static let shared = LaunchGate(defaults: .standard, domain: Bundle.main.bundleIdentifier,
                                   dataFolder: JobQueue.storeURL.deletingLastPathComponent())

    private(set) var isOpen: Bool
    @ObservationIgnored private var waiting: [@MainActor () -> Void] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults, domain: String?, dataFolder: URL) {
        self.defaults = defaults
        // Of the app itself: `object(forKey:)` would also see the global domain. No domain = no saved settings yet.
        let settings = domain.map { defaults.persistentDomain(forName: $0) ?? [:] }
        let fm = FileManager.default
        let hasData = fm.fileExists(atPath: dataFolder.path)
            && (try? fm.contentsOfDirectory(atPath: dataFolder.path))?.allSatisfy { $0 == ".DS_Store" } != true
        let needed = FirstRun.isNeeded(settings: settings, hasData: hasData)
        isOpen = !needed
        // Quitting without an answer: ask again, whatever was saved by then.
        if needed { defaults.set(false, forKey: FirstRun.doneKey) }
    }

    /// Now, or when the screen is closed.
    func whenOpen(_ action: @escaping @MainActor () -> Void) {
        if isOpen { action() } else { waiting.append(action) }
    }

    /// Finished or skipped.
    func finish() {
        guard !isOpen else { return }
        defaults.set(true, forKey: FirstRun.doneKey)
        isOpen = true
        let all = waiting
        waiting = []
        all.forEach { $0() }
    }
}
