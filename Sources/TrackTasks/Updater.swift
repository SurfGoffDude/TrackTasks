import AppKit
import Sparkle
import TrackTasksCore

/// Updates of the published app through Sparkle. Nothing of Sparkle is created, and nothing goes to the network,
/// until the policy allows it.
@Observable @MainActor
final class Updater: NSObject {
    static let enabledKey = "checkUpdates"
    static let shared = Updater()

    private(set) var gate: RestartGate?
    /// Why the last attempt to start Sparkle failed.
    private(set) var failure = ""

    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let brewPrefixes: [URL]
    /// Tests: a local feed instead of the one in `Info.plist`.
    @ObservationIgnored private let testFeed: String?
    @ObservationIgnored private let makeDriver: @MainActor (Bundle) -> any SPUUserDriver
    @ObservationIgnored private(set) var sparkle: SPUUpdater?
    @ObservationIgnored private let source: UpdatePolicy.Source?
    /// Tests: how a check ended.
    @ObservationIgnored var onCycleEnd: (@MainActor (Error?) -> Void)?

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard, brewPrefixes: [URL] = UpdatePolicy.brewPrefixes,
         testFeed: String? = nil,
         makeDriver: @escaping @MainActor (Bundle) -> any SPUUserDriver = { SPUStandardUserDriver(hostBundle: $0, delegate: nil) }) {
        self.bundle = bundle
        self.defaults = defaults
        self.brewPrefixes = brewPrefixes
        self.testFeed = testFeed
        self.makeDriver = makeDriver
        source = UpdatePolicy.Source(feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                                     key: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    }

    var enabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
    var version: String { bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? CLI.version }

    /// As of the last `refresh`: the menu asks often, and this reads the disk.
    private(set) var availability = UpdatePolicy.Availability.noSource

    /// Homebrew may take over or let go of the copy while the app works.
    @discardableResult func refresh() -> UpdatePolicy.Availability {
        availability = current
        return availability
    }

    private var current: UpdatePolicy.Availability {
        UpdatePolicy.availability(source: source, app: bundle.bundleURL, enabled: enabled, brewPrefixes: brewPrefixes)
    }

    /// Once at launch.
    func start(gate: RestartGate) {
        self.gate = gate
        apply()
    }

    /// The switch in Settings was turned.
    func apply() {
        if refresh() == .ready { prepare() }
        sparkle?.automaticallyChecksForUpdates = availability == .ready
    }

    /// «Проверить обновления…» — the user's own request, works also with the switch off.
    func check() {
        guard refresh().mayCheckByHand, prepare() else { return }
        sparkle?.checkForUpdates()
    }

    @discardableResult private func prepare() -> Bool {
        if sparkle != nil { return true }
        let u = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: makeDriver(bundle), delegate: self)
        // Before the start: it may begin the overdue check.
        u.automaticallyChecksForUpdates = availability == .ready
        u.automaticallyDownloadsUpdates = false
        u.sendsSystemProfile = false
        // By default Sparkle names the versions of the app and of itself.
        u.userAgentString = "TrackTasks"
        do {
            try u.start()
        } catch {
            failure = error.localizedDescription
            return false
        }
        failure = ""
        sparkle = u
        return true
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { MainActor.assumeIsolated { testFeed } }

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try MainActor.assumeIsolated {
            let a = current
            guard updateCheck == .updates ? a.mayCheckByHand : a == .ready else {
                throw Self.refused(a.explanation.isEmpty ? "Проверка обновлений выключена" : a.explanation)
            }
        }
    }

    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    nonisolated func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    nonisolated func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        let offered = updateItem.versionString
        try MainActor.assumeIsolated {
            guard UpdatePolicy.isNewer(offered, than: version) else {
                throw Self.refused("Версия \(offered) не новее установленной \(version)")
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { gate?.postpone(installHandler) ?? false }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            // A postponed restart keeps its cycle open; this one ended without it.
            gate?.cancel()
            onCycleEnd?(error)
        }
    }

    nonisolated private static func refused(_ why: String) -> NSError {
        NSError(domain: "TrackTasks.Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
    }
}

/// Only for the quit: everything else is SwiftUI's.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Updater.shared.gate?.mayTerminate(byUpdater: Self.askedByUpdater) ?? true ? .terminateNow : .terminateCancel
    }

    /// Sparkle asks the app to quit with an Apple event of its helper; ⌘Q and the menu have none.
    private static var askedByUpdater: Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == kAEQuitApplication,
              let pid = e.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "org.sparkle-project.Sparkle.Updater"
    }
}
