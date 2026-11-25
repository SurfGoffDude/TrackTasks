import Foundation
import Testing
@testable import TrackTasksCore

struct FirstRunTests {
    @Test func newUser() {
        #expect(FirstRun.isNeeded(settings: [:], hasData: false))
        #expect(FirstRun.isNeeded(settings: ["NSWindow Frame main": "1", "SULastCheckTime": 1, "com.apple.x": 1, "AppleLanguages": []], hasData: false))
    }

    @Test func savedSettingsOrData() {
        #expect(!FirstRun.isNeeded(settings: ["rootPath": "/p"], hasData: false))
        #expect(!FirstRun.isNeeded(settings: ["limitsCache": Data()], hasData: false))
        #expect(!FirstRun.isNeeded(settings: [:], hasData: true))
        #expect(!FirstRun.isNeeded(settings: nil, hasData: false))
    }

    @Test func theAnswerIsRemembered() {
        #expect(!FirstRun.isNeeded(settings: [FirstRun.doneKey: true], hasData: false))
        // Closed without an answer; the folder has been chosen already.
        #expect(FirstRun.isNeeded(settings: [FirstRun.doneKey: false, "rootPath": "/p"], hasData: true))
    }
}

struct ExampleProjectTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-example-\(UUID().uuidString)")

    @Test func created() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let e = try ExampleProject.create(in: root, today: "2026-11-25")
        let p = Codec.project(at: e.project, category: ExampleProject.category)
        #expect(p.displayName == ExampleProject.name && p.hasAbout && p.tasks.count == 1)
        let t = try #require(p.tasks.first)
        #expect(t.fileName == e.task.lastPathComponent && t.status == .todo && t.size == "s" && t.problems.isEmpty && t.verify.isEmpty)
        #expect(p.verify.isEmpty)
        #expect(FileManager.default.fileExists(atPath: SpecDoc.url(in: e.project).path))
    }

    @Test func existingFolderIsNotTouched() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default, dir = ExampleProject.url(in: root)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let mine = Data("моё".utf8)
        try mine.write(to: dir.appendingPathComponent("about.md"))
        #expect(throws: ExampleProject.Failure.self) { try ExampleProject.create(in: root) }
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["about.md"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("about.md")) == mine)
    }

    @Test func emptyFolderFileAndLinkAreNotTouched() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default, dir = ExampleProject.url(in: root)
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        #expect(throws: ExampleProject.Failure.self) { try ExampleProject.create(in: root) }
        try fm.removeItem(at: dir)
        try Data().write(to: dir)
        #expect(throws: ExampleProject.Failure.self) { try ExampleProject.create(in: root) }
        try fm.removeItem(at: dir)
        try fm.createSymbolicLink(at: dir, withDestinationURL: elsewhere)
        #expect(throws: ExampleProject.Failure.self) { try ExampleProject.create(in: root) }
        try fm.removeItem(at: dir)
        try fm.createSymbolicLink(at: dir, withDestinationURL: root.appendingPathComponent("nowhere"))
        #expect(throws: ExampleProject.Failure.self) { try ExampleProject.create(in: root) }
        #expect(try fm.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }
}
