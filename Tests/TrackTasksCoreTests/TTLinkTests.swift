import Foundation
import Testing
@testable import TrackTasksCore

struct TTLinkTests {
    private let fm = FileManager.default
    private let dir: URL, helper: URL, path: URL
    private let ours = Data([0xCF, 0xFA, 0xED, 0xFE]) + Data("…TrackTasks…".utf8)
    init() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("tt-link-\(UUID().uuidString)")
        helper = TTLink.helper(in: dir.appendingPathComponent("TrackTasks.app"))
        path = dir.appendingPathComponent("bin/tt")
        for u in [helper, path] { try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try ours.write(to: helper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    }

    @Test func copyBecomesALink() throws {
        defer { try? fm.removeItem(at: dir) }
        try ours.write(to: path)
        #expect(TTLink.inspect(path, helper: helper) == .copy)
        try TTLink.link(path, helper: helper)
        #expect(TTLink.inspect(path, helper: helper) == .linked)
        // Nothing is left over, and once more changes nothing.
        try TTLink.link(path, helper: helper)
        #expect(try fm.contentsOfDirectory(atPath: path.deletingLastPathComponent().path) == ["tt"])
        // The update replaces the app: the link leads to the new one.
        try (ours + Data("2".utf8)).write(to: helper)
        #expect(try Data(contentsOf: path) == ours + Data("2".utf8))
    }

    @Test func missingIsCreated() throws {
        defer { try? fm.removeItem(at: dir) }
        try fm.removeItem(at: path.deletingLastPathComponent())
        #expect(TTLink.inspect(path, helper: helper) == .missing)
        try TTLink.link(path, helper: helper)
        #expect(TTLink.inspect(path, helper: helper) == .linked)
    }

    @Test func foreignIsNotTouched() throws {
        defer { try? fm.removeItem(at: dir) }
        let other = dir.appendingPathComponent("Cellar/tt")
        try fm.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ours.write(to: other)
        let script = Data("#!/bin/sh\n# TrackTasks\n".utf8)
        try script.write(to: path)
        #expect(throws: TTLink.Refused.self) { try TTLink.link(path, helper: helper) }
        #expect(try Data(contentsOf: path) == script)
        for target in [other, dir.appendingPathComponent("gone")] {
            try fm.removeItem(at: path)
            try fm.createSymbolicLink(at: path, withDestinationURL: target)
            #expect(throws: TTLink.Refused.self) { try TTLink.link(path, helper: helper) }
            #expect(try fm.destinationOfSymbolicLink(atPath: path.path) == target.path)
        }
    }

    @Test func noLinkToATemporaryCopyOrToNothing() throws {
        defer { try? fm.removeItem(at: dir) }
        let temporary = dir.appendingPathComponent("AppTranslocation/x/d/TrackTasks.app/Contents/Helpers/tt")
        try fm.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ours.write(to: temporary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        #expect(throws: TTLink.Refused.self) { try TTLink.link(path, helper: temporary) }
        #expect(throws: TTLink.Refused.self) { try TTLink.link(path, helper: dir.appendingPathComponent("no")) }
        #expect(!fm.fileExists(atPath: path.path))
    }
}
