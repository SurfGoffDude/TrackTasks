import Foundation
import Testing
@testable import TrackTasksCore

@Suite("DangerMode")
struct DangerModeTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let p = "/projects/a"

    func on(_ d: DangerMode.Duration = .hour) -> DangerMode {
        var m = DangerMode()
        let ok = m.enable(p, name: "A", typed: " A ", d, now: now)
        #expect(ok)
        return m
    }
    func auto(_ m: DangerMode, _ job: DangerMode.JobFacts = .init(), project: String? = nil, at t: TimeInterval = 1) -> [DangerMode.Action] {
        DangerMode.Action.allCases.filter { m.allows($0, job, project: project ?? p, now: now.addingTimeInterval(t)) }
    }

    @Test func offAllowsNothing() { #expect(auto(DangerMode()).isEmpty) }

    @Test func onNeverMergesOrPushes() {
        #expect(auto(on()) == [.fullAccess, .answerRequest, .approvePlan, .autoFix, .setup, .teardown, .addDependency, .worktreeOnDirtyMain])
    }

    @Test func otherProjectIsOff() { #expect(auto(on(), project: "/projects/b").isEmpty) }

    @Test func foreignTextAllowsNothing() { #expect(auto(on(), .init(foreign: true)).isEmpty) }

    @Test func scheduledWorkIsNeverMerged() {
        var m = DangerMode()
        let ok = m.enable(p, name: "A", typed: "A", .hour, autopilot: true, verify: "v", now: now)
        #expect(ok)
        #expect(auto(m).contains(.merge))
        #expect(auto(m, .init(scheduled: true)) == auto(on()))
    }

    @Test func reviewPlanAndConflictsHaveNoFullAccess() {
        #expect(!auto(on(), .init(editsCode: false)).contains(.fullAccess))
        #expect(!auto(on(), .init(resolvesConflicts: true)).contains(.fullAccess))
        // But their requests are answered.
        #expect(auto(on(), .init(editsCode: false)).contains(.answerRequest))
        #expect(auto(on(), .init(resolvesConflicts: true)).contains(.answerRequest))
        #expect(!auto(on(), .init(editsCode: false, foreign: true)).contains(.answerRequest))
        #expect(!auto(on(), .init(editsCode: false), at: 3600).contains(.answerRequest))
    }

    @Test func expiry() {
        #expect(auto(on(), at: 3599).contains(.fullAccess))
        #expect(auto(on(), at: 3600).isEmpty)
        #expect(auto(on(.eightHours), at: 8 * 3600 - 1).contains(.fullAccess))
        #expect(auto(on(.eightHours), at: 8 * 3600).isEmpty)
        #expect(!auto(on(.untilOff), at: 1e8).isEmpty)
        var m = on()
        #expect(m.nextExpiry(now: now) == now.addingTimeInterval(3600))
        m.disable(p)
        #expect(auto(m).isEmpty)
    }

    @Test func expiredRunHasNoBypassFlag() {
        func args(_ t: TimeInterval) -> [String] {
            ClaudeArgs.permissions(bypass: on().allows(.fullAccess, .init(), project: p, now: now.addingTimeInterval(t)))
        }
        #expect(args(1) == ["--dangerously-skip-permissions"])
        #expect(!args(3600).contains("--dangerously-skip-permissions"))
    }

    @Test func clockBackLongTermAndVersionAreOff() {
        #expect(auto(on(), at: -1).isEmpty)
        var m = on()
        m.grants[p]?.until = now.addingTimeInterval(9 * 3600)
        #expect(auto(m).isEmpty)
        m = on(); m.version = 2
        #expect(auto(m).isEmpty)
    }

    @Test func wrongNameDoesNotEnable() {
        var m = DangerMode()
        let wrong = m.enable(p, name: "A", typed: "a", .hour, now: now)
        let empty = m.enable(p, name: "", typed: "", .hour, now: now)
        #expect(!wrong && !empty)
        #expect(m == DangerMode())
    }

    @Test func pathSpellingIsTheSameProject() { #expect(on().isOn("/projects/./a/", now: now.addingTimeInterval(1))) }

    @Test func restartKeepsTermAndBrokenFileIsOff() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("danger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("danger-mode.json")
        #expect(DangerMode.load(url).mode == DangerMode())
        try on().save(url)
        #expect(DangerMode.load(url).mode == on())
        #expect(auto(DangerMode.load(url).mode, at: 3600).isEmpty)
        try Data("{oops".utf8).write(to: url)
        let r = DangerMode.load(url)
        #expect(r.mode == DangerMode())
        #expect(r.problem != nil)
    }

    @Test func projectFilesCannotEnable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("danger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("---\nname: A\ndanger: true\ndangerMode: true\n---\n".utf8).write(to: dir.appendingPathComponent("about.md"))
        let task = dir.appendingPathComponent("20261123-000000-x.md")
        try Data("---\ntitle: \"x\"\nstatus: todo\ndanger: true\nbypassPermissions: true\n---\n\nтекст\n".utf8).write(to: task)
        let t = try #require(Codec.task(at: task))
        // The only input from a task is `source:`, and it only forbids.
        #expect(auto(DangerMode(), .init(foreign: !t.source.isEmpty), project: dir.path).isEmpty)
        #expect(DangerMode.load(dir.appendingPathComponent("danger-mode.json")).mode.active(now: now).isEmpty)
    }

    @Test func oldSettingOnlyAsks() {
        #expect(DangerMode.asksAboutOldSetting(true))
        #expect(!DangerMode.asksAboutOldSetting(false))
        #expect(!DangerMode.asksAboutOldSetting(nil))
        #expect(DangerMode().active(now: now).isEmpty)
    }

    @Test func worktreeLeavesUncommittedMainAlone() throws {
        let t = DiffCollectorTests()
        let d = try t.repo()
        let wt = d.deletingLastPathComponent().appendingPathComponent(d.lastPathComponent + "-wt")
        defer { for u in [d, wt] { try? FileManager.default.removeItem(at: u) } }
        try t.write("old\n", "a.txt", d)
        t.commit(d)
        try t.write("mine\n", "a.txt", d)
        try t.write("staged\n", "s.txt", d)
        _ = DiffCollectorTests.git(["add", "s.txt"], d)
        try t.write("new\n", "n.txt", d)
        let before = DiffCollectorTests.git(["status", "--porcelain"], d).out

        #expect(DiffCollectorTests.git(WorktreeGit.add(branch: "tracktasks/x", path: wt.path, base: "HEAD"), d).ok)
        #expect(try String(contentsOf: wt.appendingPathComponent("a.txt"), encoding: .utf8) == "old\n")
        try t.write("agent\n", "a.txt", wt)
        try t.write("x\n", "tasks/x.md", wt)
        #expect(DiffCollectorTests.git(WorktreeGit.stage(excluding: ["node_modules"]), wt).ok)
        #expect(DiffCollectorTests.git(["commit", "-q", "-m", "job"], wt).ok)

        #expect(DiffCollectorTests.git(["status", "--porcelain"], d).out == before)
        #expect(try String(contentsOf: d.appendingPathComponent("a.txt"), encoding: .utf8) == "mine\n")
        #expect(DiffCollectorTests.git(["show", "--name-only", "--format=", "tracktasks/x"], d).out == "a.txt\n")
    }
}
