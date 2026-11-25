import CoreServices
import Foundation
import Testing
@testable import TrackTasksCore

@Suite("FSChange.classify")
struct ClassifyTests {
    static let root = "/Users/me/Projects"
    static let proj = root + "/Swift/App"
    static let projects = [proj: proj]
    static let skipDirs: Set<String> = ["node_modules", "build", "dist"]
    static let ignored: Set<String> = ["keys", "node_modules"]

    static func ev(_ path: String, _ flags: Int...) -> FileWatcher.Event {
        FileWatcher.Event(path: path, flags: FSEventStreamEventFlags(flags.reduce(0, |)))
    }

    static let file = kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified
    static let newDir = kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated
    static let rescan = kFSEventStreamEventFlagMustScanSubDirs

    func classify(_ events: FileWatcher.Event..., projects: [String: String] = Self.projects,
                  skipExempt: [String] = []) -> FSChange {
        FSChange.classify(events, projects: projects, rootReal: Self.root, skipExempt: skipExempt,
                          skipDirs: Self.skipDirs, ignoredFolders: Self.ignored)
    }

    @Test func taskFileReloadsProject() {
        let c = classify(Self.ev(Self.proj + "/tasks/20261116-a.md", Self.file))
        #expect(c.tasks == [Self.proj])
        #expect(c.git.isEmpty && c.touched.isEmpty && !c.structure)
    }

    @Test func aboutAndTasksDirReloadProject() {
        let c = classify(Self.ev(Self.proj + "/about.md", Self.file), Self.ev(Self.proj + "/tasks/", Self.newDir))
        #expect(c.tasks == [Self.proj])
        #expect(!c.structure)
    }

    @Test func schedulesReloadProject() {
        let c = classify(Self.ev(Self.proj + "/automations/a.md", Self.file))
        #expect(c.tasks == [Self.proj] && c.git.isEmpty && c.touched.isEmpty)
        #expect(classify(Self.ev(Self.proj + "/automations/", Self.newDir)).tasks == [Self.proj])
        let code = classify(Self.ev(Self.proj + "/automations/run.py", Self.file))
        #expect(code.tasks.isEmpty && code.touched == [Self.proj])
    }

    @Test func specReloadsProject() {
        let c = classify(Self.ev(Self.proj + "/SPECTRACK.md", Self.file))
        #expect(c.tasks == [Self.proj])
        #expect(c.git.isEmpty && c.touched.isEmpty)
        #expect(classify(Self.ev(Self.proj + "/docs/spectrack.md", Self.file)).tasks.isEmpty)
    }

    @Test func workflowReloadsProjectAndGit() {
        let c = classify(Self.ev(Self.proj + "/workflows/main.md", Self.file))
        #expect(c.tasks == [Self.proj] && c.git == [Self.proj])
        #expect(classify(Self.ev(Self.proj + "/workflows/sub/x.md", Self.file)).tasks.isEmpty)
    }

    @Test func gitObjectsIgnoredButIndexRefreshes() {
        let ignored = classify(Self.ev(Self.proj + "/.git/objects/ab/cdef", Self.file),
                               Self.ev(Self.proj + "/.git/worktrees/x/HEAD", Self.file),
                               Self.ev(Self.proj + "/.git/index.lock", Self.file))
        #expect(ignored.isEmpty)
        let index = classify(Self.ev(Self.proj + "/.git/index", Self.file))
        #expect(index.git == [Self.proj])
        #expect(index.touched.isEmpty)
    }

    @Test func gitRefNamedBuildIsNotSkipped() {
        let c = classify(Self.ev(Self.proj + "/.git/refs/heads/build", Self.file))
        #expect(c.git == [Self.proj])
    }

    @Test func nodeModulesAndBuildIgnored() {
        let c = classify(Self.ev(Self.proj + "/node_modules/react/index.js", Self.file),
                         Self.ev(Self.proj + "/web/dist/app.js", Self.file),
                         Self.ev(Self.proj + "/.build/debug/x.o", Self.file))
        #expect(c.isEmpty)
    }

    @Test func workingFileTouchesAndRefreshesGit() {
        let c = classify(Self.ev(Self.proj + "/Sources/App/Store.swift", Self.file))
        #expect(c.touched == [Self.proj])
        #expect(c.git == [Self.proj])
        #expect(c.tasks.isEmpty)
    }

    @Test func newProjectFolderTriggersRescan() {
        #expect(classify(Self.ev(Self.root + "/Swift/NewApp", Self.newDir)).structure)
        #expect(classify(Self.ev(Self.root + "/NewCategory", Self.newDir)).structure)
        // Deeper, ignored, hidden or worktree folders don't.
        #expect(!classify(Self.ev(Self.root + "/Swift/NewApp/src", Self.newDir)).structure)
        #expect(!classify(Self.ev(Self.root + "/keys", Self.newDir)).structure)
        #expect(!classify(Self.ev(Self.root + "/.Trash", Self.newDir)).structure)
        #expect(!classify(Self.ev(Self.root + "/Swift/App-worktrees", Self.newDir)).structure)
        // Plain file at root level isn't a structure change.
        #expect(!classify(Self.ev(Self.root + "/notes.txt", Self.file)).structure)
    }

    @Test func projectFolderRemoved() {
        let removed = Self.ev(Self.proj, kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRemoved)
        #expect(classify(removed).structure)
    }

    @Test func mustRescanOnRootVsInsideProject() {
        #expect(classify(Self.ev(Self.root, Self.rescan)).structure)
        let inside = classify(Self.ev(Self.proj + "/Sources", Self.rescan))
        #expect(!inside.structure)
        #expect(inside.tasks == [Self.proj])
        #expect(inside.git == [Self.proj])
    }

    @Test func projectInsideSkipDirIsExempt() {
        let p = Self.root + "/build/Tool"
        let ev = Self.ev(p + "/tasks/a.md", Self.file)
        #expect(classify(ev, projects: [p: p]).isEmpty)
        #expect(classify(ev, projects: [p: p], skipExempt: [p]).tasks == [p])
    }

    @Test func trailingSlashNormalized() {
        let c = classify(Self.ev(Self.proj + "/about.md/", Self.file))
        #expect(c.tasks == [Self.proj])
    }
}
