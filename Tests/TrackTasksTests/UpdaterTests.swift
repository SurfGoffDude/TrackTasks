import AppKit
import CryptoKit
import Foundation
import Network
import Sparkle
import Testing
import TrackTasksCore
@testable import TrackTasks

/// The real Sparkle with its installer, a temporary app, a key made here and a local feed. The user's settings and
/// Keychain aren't touched.
@MainActor @Suite(.serialized) struct UpdaterTests {
    private let fm = FileManager.default
    private let box: Box

    /// A temporary app 1.0 with everything around it.
    @MainActor final class Box {
        let id = "local.tracktasks.test.\(UUID().uuidString.prefix(8))"
        let dir: URL, app: URL, defaults: UserDefaults, server: FeedServer, key = Curve25519.Signing.PrivateKey()
        var updater: Updater!
        let driver = TestDriver()
        var ended: [Error?] = []

        init() throws {
            // With /private: the installer compares the path with that of the running app.
            dir = URL(fileURLWithPath: TaskRepos.canonical(FileManager.default.temporaryDirectory)).appendingPathComponent("tt-sparkle-\(UUID().uuidString)")
            app = dir.appendingPathComponent("Installed/Probe.app")
            defaults = UserDefaults(suiteName: id)!
            server = try FeedServer()
        }
        func clean() {
            server.stop()
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.forceTerminate() }
            updater = nil
            defaults.removePersistentDomain(forName: id)
            let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            // macOS writes the emptied settings later: what earlier runs left.
            let prefs = lib.appendingPathComponent("Preferences")
            for n in (try? FileManager.default.contentsOfDirectory(atPath: prefs.path)) ?? [] where n.hasPrefix("local.tracktasks.test.") {
                let f = prefs.appendingPathComponent(n)
                let age = ((try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date)?.timeIntervalSinceNow ?? 0
                if age < -3600 { try? FileManager.default.removeItem(at: f) }
            }
            try? FileManager.default.removeItem(at: lib.appendingPathComponent("Caches/\(id)"))
            try? FileManager.default.removeItem(at: lib.appendingPathComponent("Preferences/\(id).plist"))
            try? FileManager.default.removeItem(at: dir)
        }

        /// `stays`: a real application without windows that runs until it is asked to quit.
        func makeApp(_ url: URL, version: String, source: Bool = true, stays: Bool = false) throws {
            let fm = FileManager.default
            let exe = url.appendingPathComponent("Contents/MacOS/Probe")
            if stays {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try run("/usr/bin/osacompile", "-s", "-o", url.path, "-e", "on idle", "-e", "return 60", "-e", "end idle")
                try fm.moveItem(at: url.appendingPathComponent("Contents/MacOS/applet"), to: exe)
            } else {
                try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(atPath: "/usr/bin/true", toPath: exe.path)
            }
            var p: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "Probe", "CFBundleExecutable": "Probe",
                                    "CFBundlePackageType": "APPL", "CFBundleVersion": version, "CFBundleShortVersionString": version,
                                    "LSUIElement": true, "SUAllowsAutomaticUpdates": false, "SUVerifyUpdateBeforeExtraction": true]
            if source {
                p["SUFeedURL"] = "https://example.invalid/appcast.xml"
                p["SUPublicEDKey"] = key.publicKey.rawRepresentation.base64EncodedString()
            }
            // The applet needs its own keys too.
            if let own = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] {
                p.merge(own) { mine, _ in mine }
            }
            try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            try run("/usr/bin/codesign", "--force", "--sign", "-", url.path)
        }

        func run(_ tool: String, _ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        }

        /// Puts `version` into the feed; `tamper` changes the archive after signing, its length stays.
        func publish(_ version: String, tamper: Bool = false) throws {
            let new = dir.appendingPathComponent("New/Probe.app"), zip = dir.appendingPathComponent("Probe.zip")
            try makeApp(new, version: version)
            try run("/usr/bin/ditto", "-c", "-k", "--keepParent", new.path, zip.path)
            var data = try Data(contentsOf: zip)
            let sig = try key.signature(for: data).base64EncodedString()
            if tamper { data[data.count / 2] ^= 0xFF }
            server.files["/Probe.zip"] = data
            server.files["/appcast.xml"] = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Probe</title>
            <item><title>\(version)</title><sparkle:version>\(version)</sparkle:version><sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
            <enclosure url="\(server.url)/Probe.zip" length="\(data.count)" type="application/octet-stream" sparkle:edSignature="\(sig)"/></item>
            </channel></rss>
            """.utf8)
        }

        func launch(enabled: Bool = true, brew: URL? = nil, gate: RestartGate? = nil) throws {
            defaults.set(enabled, forKey: Updater.enabledKey)
            // The daily check is overdue.
            defaults.set(Date(timeIntervalSinceNow: -1_000_000), forKey: "SULastCheckTime")
            let d = driver
            updater = Updater(bundle: try #require(Bundle(url: app)), defaults: defaults, brewPrefixes: brew.map { [$0] } ?? [],
                              testFeed: server.url + "/appcast.xml", makeDriver: { _ in d })
            updater.onCycleEnd = { [weak self] in self?.ended.append($0) }
            updater.start(gate: gate ?? RestartGate(sources: { [] }, freeze: { _ in }, ask: { _ in }))
        }

        /// Read past the bundle's cache.
        var installed: String? {
            (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"]) as? String
        }
        func wait(_ seconds: Double = 30, _ done: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return done()
        }
    }

    init() throws {
        _ = NSApplication.shared
        box = try Box()
    }

    // MARK: Network

    @Test func offAsksNothing() async throws {
        defer { box.clean() }
        try box.makeApp(box.app, version: "1.0")
        try box.publish("2.0")
        try box.launch(enabled: false)
        #expect(box.updater.availability == .manualOnly && box.updater.sparkle == nil)
        #expect(!(await box.wait(2) { !box.server.requests.isEmpty }))
    }

    /// The same with the switch on: without it the test above would prove nothing.
    @Test func onAsksOnce() async throws {
        defer { box.clean() }
        try box.makeApp(box.app, version: "1.0")
        try box.publish("1.0")
        try box.launch()
        #expect(box.updater.availability == .ready)
        #expect(await box.wait { !box.ended.isEmpty })
        #expect(!(await box.wait(1) { box.server.requests.count > 1 }))
        #expect(box.server.requests.count == 1 && box.server.requests[0].contains("User-Agent: TrackTasks\r\n"))
    }

    @Test func offStopsAWorkingUpdater() async throws {
        defer { box.clean() }
        try box.makeApp(box.app, version: "1.0")
        try box.publish("1.0")
        try box.launch()
        // The overdue first check may already have begun; after the switch there are none.
        _ = await box.wait(3) { !box.ended.isEmpty }
        box.defaults.set(false, forKey: Updater.enabledKey)
        box.updater.apply()
        let before = box.server.requests.count
        box.updater.sparkle?.checkForUpdatesInBackground()
        #expect(!(await box.wait(2) { box.server.requests.count > before }))
    }

    @Test func homebrewAndLocalBuildsAskNothing() async throws {
        defer { box.clean() }
        try box.makeApp(box.app, version: "1.0")
        try box.publish("2.0")
        let cask = box.dir.appendingPathComponent("brew/Caskroom/tracktasks/1.0")
        try fm.createDirectory(at: cask, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: cask.appendingPathComponent("TrackTasks.app"), withDestinationURL: box.app)
        try box.launch(brew: box.dir.appendingPathComponent("brew"))
        box.updater.check()
        #expect(box.updater.availability == .homebrew && box.updater.sparkle == nil)

        let local = try Box()
        defer { local.clean() }
        try local.makeApp(local.app, version: "1.0", source: false)
        try local.publish("2.0")
        try local.launch()
        local.updater.check()
        #expect(local.updater.availability == .noSource && local.updater.sparkle == nil)
        #expect(!(await box.wait(2) { !box.server.requests.isEmpty || !local.server.requests.isEmpty }))
    }

    @Test func requestTellsNothing() async throws {
        defer { box.clean() }
        try box.makeApp(box.app, version: "1.0")
        try box.publish("1.0")
        try box.launch(enabled: false)
        // By hand: also with the switch off.
        box.updater.check()
        #expect(await box.wait { !box.ended.isEmpty })
        #expect(box.server.requests.count == 1)
        let r = try #require(box.server.requests.first)
        #expect(r.hasPrefix("GET /appcast.xml HTTP/1.1"))
        #expect(r.contains("User-Agent: TrackTasks\r\n"))
        #expect(!r.contains("1.0\r\n") && !r.lowercased().contains("sparkle/"))
        #expect(!r.contains(box.id) && !r.contains(NSUserName()))
    }

    // MARK: Versions and signatures

    @Test(arguments: ["0.9", "1.0", "1.0.0", "1.x"]) func notNewerIsRefused(_ version: String) async throws {
        defer { box.clean() }
        try box.makeApp(box.app, version: "1.0")
        try box.publish(version)
        try box.launch(enabled: false)
        box.updater.check()
        #expect(await box.wait { !box.ended.isEmpty })
        #expect(box.driver.found.isEmpty)
        #expect(box.server.requests.count == 1)
        #expect(box.installed == "1.0")
    }

    /// Without it the next test could pass for an unrelated reason.
    @Test func signedUpdateIsInstalledAfterAgreement() async throws {
        defer { box.clean() }
        try box.makeApp(box.app, version: "1.0")
        try box.publish("2.0")
        try box.launch(enabled: false)
        box.driver.agrees = false
        box.updater.check()
        #expect(await box.wait { box.driver.found == ["2.0"] && !box.ended.isEmpty })
        // Not agreed: nothing is even downloaded.
        #expect(box.server.requests.count == 1 && box.installed == "1.0")
        box.driver.agrees = true
        box.updater.check()
        #expect(await box.wait { box.installed == "2.0" }, "\(box.driver.errors)")
    }

    @Test func wrongSignatureIsRefused() async throws {
        defer { box.clean() }
        try box.makeApp(box.app, version: "1.0")
        try box.publish("2.0", tamper: true)
        try box.launch(enabled: false)
        box.updater.check()
        #expect(await box.wait { !box.ended.isEmpty })
        #expect(box.server.requests.contains { $0.hasPrefix("GET /Probe.zip") })
        // Exactly the signature, not a broken archive.
        var causes: [Int] = [], e = box.driver.errors.first
        while let x = e {
            causes.append(x.code)
            e = x.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        #expect(box.driver.errors.count == 1 && causes.contains(Int(SUError.validationError.rawValue)), "\(causes) \(box.driver.errors)")
        #expect(!box.driver.ready && box.installed == "1.0")
        #expect(!(await box.wait(2) { box.installed != "1.0" }))
    }

    /// The gate inside the real update: agreed to, but a task is running.
    @Test func busyAppIsNotReplaced() async throws {
        defer { box.clean() }
        let job = Job(kind: .runTask, title: "Задача", projectID: nil, projectName: "p", cwd: box.dir, prompt: "x", systemPrompt: "")
        job.state = .running
        var question: (@MainActor (Bool) -> Void)?
        let gate = RestartGate(sources: { job.state == .running ? [.task(job.title)] : [] }, freeze: { _ in }, ask: { question = $0 })
        try box.makeApp(box.app, version: "1.0", stays: true)
        try box.run("/usr/bin/open", "-g", "-n", box.app.path)
        func running() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: box.id).isEmpty }
        #expect(await box.wait(10) { running() })
        try box.publish("2.0")
        try box.launch(enabled: false, gate: gate)
        box.updater.check()
        #expect(await box.wait { gate.isPending }, "\(box.driver.errors)")
        #expect(!(await box.wait(2) { box.installed != "1.0" || !running() }))
        job.state = .done
        #expect(await box.wait(5) { question != nil })
        #expect(box.installed == "1.0")
        question?(true)
        #expect(await box.wait(10) { !running() }, "still running, installing=\(box.driver.installing) ended=\(box.ended.count) pending=\(gate.isPending)")
        #expect(await box.wait { box.installed == "2.0" }, "\(box.driver.errors)")
    }
}

/// Answers for the user.
@MainActor final class TestDriver: NSObject, SPUUserDriver {
    var agrees = true
    var found: [String] = []
    var errors: [NSError] = []
    var ready = false
    var installing = false

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        found.append(appcastItem.versionString)
        reply(agrees ? .install : .dismiss)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { errors.append(error as NSError); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { ready = true; reply(.install) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { installing = true }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
    func showUpdateInFocus() {}
}

/// Serves `files` on localhost and remembers the requests. Everything on the main queue.
final class FeedServer: @unchecked Sendable {
    private let listener: NWListener
    private(set) var requests: [String] = []
    var files: [String: Data] = [:]
    private let port: UInt16
    var url: String { "http://127.0.0.1:\(port)" }

    init() throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: p)
        listener = l
        let up = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { if case .ready = $0 { up.signal() } }
        // Replaced once the port is known; nobody connects before.
        let handler = Handler()
        l.newConnectionHandler = { c in handler.accept?(c) }
        l.start(queue: DispatchQueue(label: "feed"))
        guard up.wait(timeout: .now() + 5) == .success, let n = l.port else { throw CocoaError(.featureUnsupported) }
        port = n.rawValue
        handler.accept = { [weak self] c in
            c.start(queue: .main)
            self?.read(c, Data())
        }
    }
    private final class Handler: @unchecked Sendable { var accept: ((NWConnection) -> Void)? }

    func stop() { listener.cancel() }

    private func read(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, _ in
            guard let self else { return c.cancel() }
            let all = got + (d ?? Data())
            guard let end = all.range(of: Data("\r\n\r\n".utf8)) else { return done ? c.cancel() : read(c, all) }
            let head = String(decoding: all[..<end.upperBound], as: UTF8.self)
            requests.append(head)
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let body = files[path.split(separator: "?").first.map(String.init) ?? path]
            let status = body == nil ? "404 Not Found" : "200 OK"
            let out = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n".utf8) + (body ?? Data())
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}
