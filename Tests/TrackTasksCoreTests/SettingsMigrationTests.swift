import Foundation
import Testing
@testable import TrackTasksCore

private final class FakeDomains: SettingsDomains {
    enum Broken { case readLegacy, readCurrent, write, loseKey, loseMarker }
    var all: [String: [String: Any]] = [:]
    var broken: Broken?
    var writes = 0

    func read(_ domain: String) throws -> [String: Any] {
        if (broken == .readLegacy && domain == "old") || (broken == .readCurrent && domain == "new") {
            throw SettingsMigration.Failure.unreadable(domain)
        }
        return all[domain] ?? [:]
    }

    func write(_ values: [String: Any], to domain: String) throws {
        writes += 1
        if broken == .write { throw SettingsMigration.Failure.notSaved }
        var values = values
        if broken == .loseKey { values["rootPath"] = nil }
        if broken == .loseMarker { values[SettingsMigration.markerKey] = nil }
        all[domain] = values
    }
}

struct SettingsMigrationTests {
    private let settings: [String: Any] = [
        "queuePaused": true, "worktreeScriptApprovals": Data([1, 2, 3]), "rootPath": "/p", "extraFolders": ["/a", "/b"],
        "eventsPort": 8123, "spend-x": 1.5, "date": Date(timeIntervalSince1970: 1000), "nested": ["a": ["b": 1]],
        "NSWindow Frame main": "0 0 1 1",
    ]

    private func launch(_ domains: SettingsDomains, _ old: String = "old", _ new: String = "new", running: Bool = false) -> (error: Error?, started: Bool) {
        var started = false
        let error = SettingsMigration.launch(domains: domains, previousIsRunning: running, from: old, to: new) { started = true }
        return (error, started)
    }

    private func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { (a as NSDictionary).isEqual(to: b) }

    /// Real UserDefaults, domains of its own.
    private func withRealDomains(_ body: (UserDefaultsDomains, String, String) throws -> Void) rethrows {
        let id = UUID().uuidString
        let old = "tracktasks.test.old.\(id)", new = "tracktasks.test.new.\(id)"
        defer {
            for name in [old, new] {
                UserDefaults.standard.removePersistentDomain(forName: name)
                CFPreferencesAppSynchronize(name as CFString)
                try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Preferences/\(name).plist"))
            }
        }
        try body(UserDefaultsDomains(), old, new)
    }

    @Test func fullCopyAndSecondLaunch() throws {
        try withRealDomains { domains, old, new in
            try domains.write(settings, to: old)
            #expect(launch(domains, old, new).started)
            #expect(same(try domains.read(new), settings.merging([SettingsMigration.markerKey: true]) { $1 }))
            #expect(same(try domains.read(old), settings))

            var changed = try domains.read(new)
            changed["queuePaused"] = false
            changed["rootPath"] = nil
            try domains.write(changed, to: new)
            #expect(launch(domains, old, new).started)
            #expect(same(try domains.read(new), changed))
        }
    }

    @Test func cleanInstall() throws {
        try withRealDomains { domains, old, new in
            #expect(launch(domains, old, new).started)
            let saved = try domains.read(new)
            #expect(same(saved, [SettingsMigration.markerKey: true]))
            #expect(FirstRun.isNeeded(settings: saved, hasData: false))
        }
    }

    @Test func newValuesStay() throws {
        try withRealDomains { domains, old, new in
            try domains.write(settings, to: old)
            try domains.write(["rootPath": "/new", "own": 1], to: new)
            #expect(launch(domains, old, new).started)
            let saved = try domains.read(new)
            #expect(saved["rootPath"] as? String == "/new")
            #expect(saved["own"] as? Int == 1)
            #expect(saved["queuePaused"] as? Bool == true)
        }
    }

    @Test(arguments: [FakeDomains.Broken.readLegacy, .readCurrent, .write, .loseKey, .loseMarker])
    private func failureStartsNothing(_ broken: FakeDomains.Broken) {
        let domains = FakeDomains()
        domains.all = ["old": settings, "new": ["own": 1]]
        domains.broken = broken
        let result = launch(domains)
        #expect(result.error != nil)
        #expect(!result.started)
        #expect(same(domains.all["old"]!, settings))
        #expect(same(domains.all["new"]!, ["own": 1]))

        domains.broken = nil
        #expect(launch(domains).started)
        #expect(domains.all["new"]?["rootPath"] as? String == "/p")
    }

    @Test func previousVersionIsRunning() {
        let domains = FakeDomains()
        domains.all = ["old": settings]
        let result = launch(domains, running: true)
        #expect(result.error as? SettingsMigration.Failure == .previousIsRunning)
        #expect(!result.started)
        #expect(domains.writes == 0)
    }

    @Test func damagedFileIsNotACleanInstall() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "tracktasks.test.\(UUID().uuidString)"
        let domains = UserDefaultsDomains(preferences: folder)
        #expect(try domains.read(name).isEmpty)
        let file = folder.appendingPathComponent(name + ".plist")
        try Data("garbage".utf8).write(to: file)
        #expect(throws: SettingsMigration.Failure.unreadable(name)) { try domains.read(name) }
        try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0).write(to: file)
        #expect(try domains.read(name).isEmpty)
    }

    @Test func ttSeesTheFolder() {
        let domains = FakeDomains()
        domains.all = ["old": settings]
        func root() -> String? { SettingsMigration.value("rootPath", domains: domains, from: "old", to: "new") as? String }
        #expect(root() == "/p")
        domains.broken = .write
        #expect(!launch(domains).started)
        #expect(root() == "/p")
        domains.broken = nil
        #expect(launch(domains).started)
        #expect(root() == "/p")
        // Removed by the user after the move: not brought back.
        domains.all["new"]?["rootPath"] = nil
        #expect(root() == nil)
    }

    @Test func identifierInTheSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = NSDictionary(contentsOf: root.appendingPathComponent("Info.plist"))
        #expect(plist?["CFBundleIdentifier"] as? String == SettingsMigration.currentID)

        var files = ["Info.plist", "build.sh", "share.sh", "release.sh", "packaging/homebrew/Casks/tracktasks.rb"].map { root.appendingPathComponent($0) }
        for folder in ["Sources", "tools"] {
            let found = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            files += (found?.allObjects as? [URL] ?? []).filter { ["swift", "sh"].contains($0.pathExtension) }
        }
        #expect(files.count > 50)
        for file in files where file.lastPathComponent != "SettingsMigration.swift" {
            #expect(try !String(contentsOf: file, encoding: .utf8).contains(SettingsMigration.legacyID), "\(file.path)")
        }
    }
}
