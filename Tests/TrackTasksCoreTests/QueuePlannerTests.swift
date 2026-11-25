import Foundation
import Testing
@testable import TrackTasksCore

@Suite("QueuePlanner.decide")
struct QueuePlannerTests {
    typealias J = QueuePlanner.Job
    typealias D = QueuePlanner.Decision

    func settings(limit: Int = 3, paused: Bool = false, hold: String? = nil, worktrees: Bool = true,
                  dirty: [String] = []) -> QueuePlanner.Settings {
        .init(limit: limit, paused: paused, hold: hold, worktreesEnabled: worktrees, dirtyFiles: ["/p": dirty])
    }

    func job(_ title: String, _ state: QueuePlanner.State = .pending, cwd: String? = nil,
             lane: QueuePlanner.Lane = .code, depends: [J] = [], wave: Int? = nil, priority: String? = nil) -> J {
        J(title: title, state: state, lane: lane, cwd: cwd ?? "/p/\(title)", depends: depends.map(\.id),
          wave: wave, wavePriority: priority)
    }

    func started(_ d: [UUID: D], _ jobs: [J]) -> [String] {
        jobs.filter { d[$0.id] == .start || d[$0.id] == .needWorktree }.map(\.title)
    }

    // MARK: Limit and lanes

    @Test func limitPerLane() {
        let jobs = (1...5).map { job("c\($0)") } + (1...2).map { job("l\($0)", lane: .light) }
        let d = QueuePlanner.decide(jobs: jobs, settings: settings(limit: 2))
        #expect(started(d, jobs) == ["c1", "c2", "l1", "l2"])
        #expect(d[jobs[2].id] == .wait(.slot(limit: 2)))
    }

    @Test func runningJobsTakeSlots() {
        let jobs = [job("r1", .running), job("r2", .running), job("p1"), job("p2")]
        let d = QueuePlanner.decide(jobs: jobs, settings: settings(limit: 3))
        #expect(started(d, jobs) == ["p1"])
        #expect(d[jobs[3].id] == .wait(.slot(limit: 3)))
        #expect(d[jobs[0].id] == nil)
    }

    @Test func questionsHoldOnlyDependents() {
        var a = job("a", .done); a.awaitsAnswers = true
        let b = job("b", depends: [a]), c = job("c")
        let d = QueuePlanner.decide(jobs: [a, b, c], settings: settings())
        #expect(d[b.id] == .wait(.answers(["a"])) && d[c.id] == .start)
        var plan = job("p"); plan.awaitingPlan = true; plan.awaitsAnswers = true
        #expect(QueuePlanner.decide(jobs: [plan], settings: settings())[plan.id] == .wait(.answers([])))
    }

    // MARK: One folder — one job

    @Test func sameFolderGetsWorktree() {
        let jobs = [job("a", cwd: "/p"), job("b", cwd: "/p")]
        let d = QueuePlanner.decide(jobs: jobs, settings: settings())
        #expect(d[jobs[0].id] == .start)
        #expect(d[jobs[1].id] == .needWorktree)
    }

    @Test func sameFolderWithoutWorktreesWaits() {
        let jobs = [job("a", cwd: "/p"), job("b", cwd: "/p"), job("c", cwd: "/q")]
        let d = QueuePlanner.decide(jobs: jobs, settings: settings(worktrees: false))
        #expect(d[jobs[1].id] == .wait(.sameFolder(.worktreesOff)))
        #expect(d[jobs[2].id] == .start)
    }

    @Test func mustUseMainAndUnavailableWait() {
        var b = job("b", cwd: "/p"); b.mustUseMain = true
        var c = job("c", cwd: "/p"); c.worktreeUnavailable = true
        let jobs = [job("a", .running, cwd: "/p"), b, c]
        let d = QueuePlanner.decide(jobs: jobs, settings: settings())
        #expect(d[b.id] == .wait(.sameFolder(.plain)))
        #expect(d[c.id] == .wait(.sameFolder(.worktreeUnavailable)))
    }

    @Test func lightJobsShareFolder() {
        let jobs = [job("a", cwd: "/p"), job("b", cwd: "/p", lane: .light)]
        let d = QueuePlanner.decide(jobs: jobs, settings: settings())
        #expect(started(d, jobs) == ["a", "b"])
        #expect(d[jobs[1].id] == .start)
    }

    @Test func dirtyMainHoldsWorktree() {
        var b = job("b", cwd: "/p")
        let jobs = [job("a", .running, cwd: "/p"), b]
        let d = QueuePlanner.decide(jobs: jobs, settings: settings(dirty: ["Sources/x.swift"]))
        #expect(d[b.id] == .wait(.sameFolder(.dirtyMain(["Sources/x.swift"]))))
        // «Запустить всё равно».
        b.allowDirtyMain = true
        let d2 = QueuePlanner.decide(jobs: [jobs[0], b], settings: settings(dirty: ["Sources/x.swift"]))
        #expect(d2[b.id] == .needWorktree)
    }

    @Test func waitReasonModeUsesStoredDirtyFiles() {
        var b = job("b", cwd: "/p"); b.dirtyMain = ["a.swift"]
        let jobs = [job("a", .running, cwd: "/p"), b]
        let d = QueuePlanner.decide(jobs: jobs, settings: .init(limit: 3))
        #expect(d[b.id] == .wait(.sameFolder(.dirtyMain(["a.swift"]))))
        #expect(d[b.id].map { if case .wait(let r) = $0 { r.text } else { "" } }?.hasPrefix("ждёт коммита в main") == true)
    }

    @Test func sharedWorktreeWaits() {
        var a = job("a", .running, cwd: "/p"); a.worktree = "/wt/1"
        var b = job("b", cwd: "/p"); b.worktree = "/wt/1"
        let d = QueuePlanner.decide(jobs: [a, b], settings: settings())
        #expect(d[b.id] == .wait(.worktreeBusy))
    }

    @Test func creatingWorktreeTakesSlotNotMainFolder() {
        // The app marks a job whose worktree is being created as running with `creatingWorktree`.
        let a = job("a", .running, cwd: "/p")
        var w = job("w", .running, cwd: "/p"); w.creatingWorktree = true
        let jobs = [a, w, job("b", cwd: "/q"), job("c", cwd: "/r")]
        let d = QueuePlanner.decide(jobs: jobs, settings: settings(limit: 3))
        #expect(started(d, jobs) == ["b"])
        #expect(d[jobs[3].id] == .wait(.slot(limit: 3)))
        // It doesn't hold the main folder: alone in /p, a new job starts there directly.
        let solo = [w, job("m", cwd: "/p")]
        #expect(QueuePlanner.decide(jobs: solo, settings: settings())[solo[1].id] == .start)
        #expect(QueuePlanner.dirtyCandidates(jobs: solo, settings: settings()).isEmpty)
    }

    @Test func needWorktreeCountsForLaterJobs() {
        // a runs in main, b gets a worktree, c sees both (slot taken; main still busy → worktree too).
        let jobs = [job("a", .running, cwd: "/p"), job("b", cwd: "/p"), job("c", cwd: "/p"), job("d", cwd: "/p")]
        let d = QueuePlanner.decide(jobs: jobs, settings: settings(limit: 3))
        #expect(d[jobs[1].id] == .needWorktree)
        #expect(d[jobs[2].id] == .needWorktree)
        #expect(d[jobs[3].id] == .wait(.slot(limit: 3)))
    }

    // MARK: Dependencies

    @Test func waitsForActiveDependency() {
        let a = job("a", .running)
        let b = job("b", depends: [a])
        let d = QueuePlanner.decide(jobs: [a, b], settings: settings())
        #expect(d[b.id] == .wait(.dependencies(["a"])))
        #expect(d[b.id].map { if case .wait(let r) = $0 { r.text } else { "" } } == "ждёт зависимости: «a»")
    }

    @Test func failedDependencyCancelsWholeChain() {
        let a = job("a", .failed)
        let b = job("b", depends: [a])
        let c = job("c", depends: [b])
        let d = QueuePlanner.decide(jobs: [a, b, c], settings: settings())
        #expect(d[b.id] == .cancel(lastLine: "Цепочка прервана: зависимость «a» не выполнена"))
        // c comes later in the queue and already sees b cancelled.
        #expect(d[c.id] == .cancel(lastLine: "Цепочка прервана: зависимость «b» не выполнена"))
    }

    @Test func cancelledDependencyCancels() {
        let a = job("a", .cancelled)
        let b = job("b", depends: [a])
        #expect(QueuePlanner.decide(jobs: [a, b], settings: settings())[b.id]
            == .cancel(lastLine: "Цепочка прервана: зависимость «a» не выполнена"))
    }

    @Test func waitsForMerge() {
        var a = job("a", .done); a.worktree = "/wt/a"; a.awaitsMerge = true
        let b = job("b", depends: [a])
        let d = QueuePlanner.decide(jobs: [a, b], settings: settings())
        #expect(d[b.id] == .wait(.merge(["a"])))
        a.awaitsMerge = false
        #expect(QueuePlanner.decide(jobs: [a, b], settings: settings())[b.id] == .start)
    }

    @Test func missingDependencyIgnored() {
        let b = J(title: "b", depends: [UUID()])
        #expect(QueuePlanner.decide(jobs: [b], settings: settings())[b.id] == .start)
    }

    // MARK: Waves (each job of wave N depends on all jobs of wave N−1)

    @Test func wavesStartInOrder() {
        // 2 high + 2 medium + 1 low, no depends.
        let h1 = job("h1", wave: 1, priority: "high"), h2 = job("h2", wave: 1, priority: "high")
        var m1 = job("m1", depends: [h1, h2], wave: 2, priority: "medium")
        var m2 = job("m2", depends: [h1, h2], wave: 2, priority: "medium")
        let l1 = job("l1", depends: [m1, m2], wave: 3, priority: "low")
        var jobs = [h1, h2, m1, m2, l1]
        var d = QueuePlanner.decide(jobs: jobs, settings: settings())
        #expect(started(d, jobs) == ["h1", "h2"])
        #expect(d[m1.id] == .wait(.wave(priority: "high", done: 0, total: 2, others: [])))

        // One high done: medium still waits — «ждёт волну high (1 из 2)».
        jobs[0].state = .done; jobs[1].state = .running
        d = QueuePlanner.decide(jobs: jobs, settings: settings())
        #expect(started(d, jobs).isEmpty)
        #expect(d[m1.id].map { if case .wait(let r) = $0 { r.text } else { "" } } == "ждёт волну high (1 из 2)")

        // Both high done: both medium start, low waits.
        jobs[1].state = .done
        d = QueuePlanner.decide(jobs: jobs, settings: settings())
        #expect(started(d, jobs) == ["m1", "m2"])
        #expect(d[l1.id] == .wait(.wave(priority: "medium", done: 0, total: 2, others: [])))

        m1.state = .done; m2.state = .done
        d = QueuePlanner.decide(jobs: [jobs[0], jobs[1], m1, m2, l1], settings: settings())
        #expect(d[l1.id] == .start)
    }

    @Test func highWithMediumDependency() {
        // high depends on medium: the medium is lifted into wave 1, the high waits for it inside the wave.
        let m = job("m", wave: 1, priority: "high")
        let h = job("h", depends: [m], wave: 1, priority: "high")
        let d = QueuePlanner.decide(jobs: [h, m], settings: settings())
        #expect(d[m.id] == .start)
        #expect(d[h.id] == .wait(.dependencies(["m"])))
    }

    @Test func failedWaveCancelsNextWaves() {
        let h1 = job("h1", .failed, wave: 1, priority: "high"), h2 = job("h2", .running, wave: 1, priority: "high")
        let m1 = job("m1", depends: [h1, h2], wave: 2, priority: "medium")
        let l1 = job("l1", depends: [m1], wave: 3, priority: "low")
        var jobs = [h1, h2, m1, l1]
        // h2 still runs: the next wave waits (it isn't cancelled yet, h2 finishes first).
        #expect(QueuePlanner.decide(jobs: jobs, settings: settings())[m1.id]
            == .wait(.wave(priority: "high", done: 1, total: 2, others: [])))
        jobs[1].state = .done
        let d = QueuePlanner.decide(jobs: jobs, settings: settings())
        #expect(d[m1.id] == .cancel(lastLine: "Цепочка прервана: зависимость «h1» не выполнена"))
        #expect(d[l1.id] == .cancel(lastLine: "Цепочка прервана: зависимость «m1» не выполнена"))
    }

    @Test func waveWithOwnDependency() {
        let h = job("h", .running, wave: 1, priority: "high")
        let x = job("x", .running, wave: 2, priority: "medium")
        let m = job("m", depends: [h, x], wave: 2, priority: "medium")
        let d = QueuePlanner.decide(jobs: [h, x, m], settings: settings())
        #expect(d[m.id] == .wait(.wave(priority: "high", done: 0, total: 1, others: ["x"])))
        #expect(d[m.id].map { if case .wait(let r) = $0 { r.text } else { "" } }
            == "ждёт волну high (0 из 1) и зависимости: «x»")
    }

    @Test func waveRespectsLimitAndFolder() {
        let hs = (1...4).map { job("h\($0)", cwd: "/p", wave: 1, priority: "high") }
        let d = QueuePlanner.decide(jobs: hs, settings: settings(limit: 2, worktrees: false))
        #expect(started(d, hs) == ["h1"])
        #expect(d[hs[1].id] == .wait(.sameFolder(.worktreesOff)))
    }

    // MARK: Pause and weekly limit

    @Test func pauseHoldsEverything() {
        let jobs = [job("a"), job("b")]
        let d = QueuePlanner.decide(jobs: jobs, settings: settings(paused: true))
        #expect(d.values.allSatisfy { $0 == .wait(.paused) })
        #expect(d.count == 2)
    }

    private func stopped(_ cwd: String = "/a", until: Date? = nil) -> QueuePlanner.Job {
        var j = QueuePlanner.Job(cwd: cwd, mustUseMain: true)
        j.limitWait = true
        j.limitUntil = until
        return j
    }

    @Test func limitWaitHoldsItsFolderButNoSlot() {
        let until = Date().addingTimeInterval(600), w = stopped(until: until)
        let same = QueuePlanner.Job(cwd: "/a", mustUseMain: true), other = QueuePlanner.Job(cwd: "/b")
        let d = QueuePlanner.decide(jobs: [same, w, other], settings: .init(limit: 1))
        #expect(d[w.id] == .wait(.limitReset(until)))
        #expect(d[same.id] == .wait(.sameFolder(.plain)))
        #expect(d[other.id] == .start)
        #expect(QueuePlanner.dirtyCandidates(jobs: [w, other], settings: .init(limit: 1)).isEmpty)
        // After the reset it starts where it was; pause and the guard are stronger.
        let due = stopped()
        #expect(QueuePlanner.decide(jobs: [same, due], settings: .init(limit: 3)) == [same.id: .wait(.sameFolder(.plain)), due.id: .start])
        #expect(QueuePlanner.decide(jobs: [due], settings: .init(limit: 3, paused: true))[due.id] == .wait(.paused))
        #expect(QueuePlanner.decide(jobs: [due], settings: .init(limit: 3, hold: "лимит"))[due.id] == .wait(.limitHold("лимит")))
    }

    @Test func limitWaitsOfOneFolderDontBlockEachOther() {
        let a = stopped(), b = stopped()
        let d = QueuePlanner.decide(jobs: [a, b], settings: .init(limit: 3))
        #expect(d[a.id] == .start && d[b.id] == .wait(.sameFolder(.plain)))
    }

    @Test func limitHoldHoldsEverything() {
        let a = job("a", .failed)
        let jobs = [a, job("b"), job("c", depends: [a])]
        let d = QueuePlanner.decide(jobs: jobs, settings: settings(hold: "Осталось 5%"))
        #expect(d[jobs[1].id] == .wait(.limitHold("Осталось 5%")))
        // Even the broken chain isn't touched while the queue is held (as before).
        #expect(d[jobs[2].id] == .wait(.limitHold("Осталось 5%")))
    }

    @Test func startedJobCountsForLaterOnes() {
        // Worktree decision assumed to succeed: the next job in /p still sees the main folder busy.
        let jobs = [job("a", cwd: "/p"), job("b", cwd: "/p"), job("c", cwd: "/p")]
        let d = QueuePlanner.decide(jobs: jobs, settings: settings())
        #expect(d[jobs[1].id] == .needWorktree)
        #expect(d[jobs[2].id] == .needWorktree)
    }

    @Test func dirtySnapshotIsReadyDictionary() {
        // Snapshot for /p says clean: stale `dirtyMain` is overridden; /q is not in the snapshot → stored files.
        var b = job("b", cwd: "/p"); b.dirtyMain = ["old.swift"]
        var y = job("y", cwd: "/q"); y.dirtyMain = ["q.swift"]
        let jobs = [job("a", .running, cwd: "/p"), b, job("x", .running, cwd: "/q"), y]
        let d = QueuePlanner.decide(jobs: jobs, settings: .init(limit: 5, dirtyFiles: ["/p": []]))
        #expect(d[b.id] == .needWorktree)
        #expect(d[y.id] == .wait(.sameFolder(.dirtyMain(["q.swift"]))))
        let d2 = QueuePlanner.decide(jobs: jobs, settings: .init(limit: 5, dirtyFiles: ["/p": ["n.swift"], "/q": []]))
        #expect(d2[b.id] == .wait(.sameFolder(.dirtyMain(["n.swift"]))))
        #expect(d2[y.id] == .needWorktree)
    }

    @Test func dirtyCandidatesOnlyWhenMainFolderBusy() {
        // Lone pending jobs, dependency-blocked jobs and jobs in other folders need no git.
        let a = job("a", .running, cwd: "/p")
        let dep = job("dep", cwd: "/r")
        let jobs = [a, job("b", cwd: "/p"), job("c", cwd: "/q"), dep, job("e", cwd: "/r", depends: [dep])]
        #expect(QueuePlanner.dirtyCandidates(jobs: jobs, settings: settings()) == ["/p"])
        #expect(QueuePlanner.dirtyCandidates(jobs: [job("c", cwd: "/q")], settings: settings()).isEmpty)
        // Two pending jobs in one folder: the second may need a worktree.
        #expect(QueuePlanner.dirtyCandidates(jobs: [job("x", cwd: "/q"), job("y", cwd: "/q")], settings: settings()) == ["/q"])
        #expect(QueuePlanner.dirtyCandidates(jobs: jobs, settings: settings(paused: true)).isEmpty)
        #expect(QueuePlanner.dirtyCandidates(jobs: jobs, settings: settings(hold: "x")).isEmpty)
        #expect(QueuePlanner.dirtyCandidates(jobs: jobs, settings: settings(worktrees: false)).isEmpty)
        var allowed = jobs[1]; allowed.allowDirtyMain = true
        #expect(QueuePlanner.dirtyCandidates(jobs: [a, allowed], settings: settings()).isEmpty)
    }

    // MARK: «Опасный режим»

    @Test func forcedJobTakesWorktreeEvenWithFreeOrDirtyMain() {
        var a = job("a", cwd: "/p"); a.forceWorktree = true
        #expect(QueuePlanner.decide(jobs: [a], settings: settings())[a.id] == .needWorktree)
        #expect(QueuePlanner.decide(jobs: [a], settings: settings(dirty: ["x.swift"]))[a.id] == .needWorktree)
        #expect(QueuePlanner.dirtyCandidates(jobs: [a], settings: settings()).isEmpty)
    }

    @Test func forcedPlanningGetsWorktree() {
        var a = job("a", cwd: "/p", lane: .light); a.forceWorktree = true
        #expect(QueuePlanner.decide(jobs: [a], settings: settings())[a.id] == .needWorktree)
    }

    @Test func forcedJobNeverFallsBackToMain() {
        var a = job("a", cwd: "/p"); a.forceWorktree = true
        guard case .wait(.worktreeRequired) = QueuePlanner.decide(jobs: [a], settings: settings(worktrees: false))[a.id] else {
            Issue.record("must wait"); return
        }
        a.worktreeUnavailable = true
        guard case .wait(.worktreeRequired) = QueuePlanner.decide(jobs: [a], settings: settings())[a.id] else {
            Issue.record("must wait"); return
        }
    }

    @Test func forcedJobWaitsForUncommittedDependency() {
        var dep = job("dep", .done, cwd: "/p"); dep.doneInMain = true
        var a = job("a", cwd: "/p", depends: [dep]); a.forceWorktree = true
        #expect(QueuePlanner.dirtyCandidates(jobs: [dep, a], settings: settings()) == ["/p"])
        #expect(QueuePlanner.decide(jobs: [dep, a], settings: settings(dirty: ["x.swift"]))[a.id]
            == .wait(.sameFolder(.dirtyMain(["x.swift"]))))
        #expect(QueuePlanner.decide(jobs: [dep, a], settings: settings())[a.id] == .needWorktree)
    }

    @Test func forcedJobThatMustUseMainStaysThere() {
        var a = job("a", cwd: "/p"); a.forceWorktree = true; a.mustUseMain = true
        #expect(QueuePlanner.decide(jobs: [a], settings: settings(dirty: ["x.swift"]))[a.id] == .start)
        let busy = job("r", .running, cwd: "/p")
        #expect(QueuePlanner.decide(jobs: [busy, a], settings: settings())[a.id] == .wait(.sameFolder(.plain)))
    }

    @Test func forcedJobAllowedDirtyMainIgnoresUncommittedDependency() {
        var dep = job("dep", .done, cwd: "/p"); dep.doneInMain = true
        var a = job("a", cwd: "/p", depends: [dep]); a.forceWorktree = true; a.allowDirtyMain = true
        #expect(QueuePlanner.dirtyCandidates(jobs: [dep, a], settings: settings()).isEmpty)
        #expect(QueuePlanner.decide(jobs: [dep, a], settings: settings(dirty: ["x.swift"]))[a.id] == .needWorktree)
    }

    // MARK: worktree: always

    func always(_ title: String, depends: [J] = []) -> J {
        var j = job(title, cwd: "/p", depends: depends)
        j.alwaysWorktree = true
        return j
    }

    @Test func alwaysLeavesMainFree() {
        let jobs = (1...5).map { always("t\($0)") }
        let d = QueuePlanner.decide(jobs: jobs, settings: settings(limit: 3))
        #expect(jobs.prefix(3).allSatisfy { d[$0.id] == .needWorktree })
        #expect(jobs.suffix(2).allSatisfy { d[$0.id] == .wait(.slot(limit: 3)) })
        #expect(QueuePlanner.dirtyCandidates(jobs: jobs, settings: settings()) == ["/p"])
        // The main folder is free for a job that must run there.
        var m = job("m", cwd: "/p"); m.mustUseMain = true
        let mixed = QueuePlanner.decide(jobs: [jobs[0], jobs[1], m], settings: settings(limit: 3))
        #expect(mixed[m.id] == .start)
    }

    @Test func alwaysWaitsForDirtyMain() {
        var a = always("a")
        let s = settings(dirty: ["x.swift"])
        #expect(QueuePlanner.decide(jobs: [a], settings: s)[a.id] == .wait(.sameFolder(.dirtyMain(["x.swift"]))))
        a.allowDirtyMain = true
        #expect(QueuePlanner.decide(jobs: [a], settings: s)[a.id] == .needWorktree)
        a.mustUseMain = true
        #expect(QueuePlanner.decide(jobs: [a], settings: s)[a.id] == .start)
        #expect(QueuePlanner.dirtyCandidates(jobs: [a], settings: s).isEmpty)
    }

    @Test func alwaysNeverFallsBackToMainSilently() {
        var a = always("a")
        #expect(QueuePlanner.decide(jobs: [a], settings: settings(worktrees: false))[a.id]
            == .wait(.alwaysWorktree("worktree выключены в Настройках")))
        a.worktreeUnavailable = true
        #expect(QueuePlanner.decide(jobs: [a], settings: settings())[a.id] == .wait(.alwaysWorktree("worktree не создался")))
    }

    @Test func alwaysWithoutCommitsUsesMainInTurn() {
        let a = always("a"), b = always("b")
        var s = settings(dirty: ["x.swift"])
        s.noCommits = ["/p"]
        let d = QueuePlanner.decide(jobs: [a, b], settings: s)
        #expect(d[a.id] == .start)
        guard case .wait(.sameFolder)? = d[b.id] else { Issue.record("must wait"); return }
    }

    @Test func alwaysKeepsOtherRules() {
        var dep = job("dep", .done, cwd: "/p"); dep.worktree = "/w"; dep.awaitsMerge = true
        let a = always("a", depends: [dep])
        #expect(QueuePlanner.decide(jobs: [dep, a], settings: settings())[a.id] == .wait(.merge(["dep"])))
        var light = job("l", cwd: "/p", lane: .light); light.alwaysWorktree = true
        #expect(QueuePlanner.decide(jobs: [light], settings: settings())[light.id] == .start)
        var own = always("own"); own.worktree = "/w2"
        #expect(QueuePlanner.decide(jobs: [own], settings: settings(worktrees: false, dirty: ["x"]))[own.id] == .start)
    }

    @Test func worktreeFields() throws {
        let about = "---\nname: P\nverify: swift test # быстро\ncustom: 1\n---\n\n# P\n"
        let on = Frontmatter.setting("worktree", to: "always", in: about)
        #expect(on.contains("worktree: always") && on.contains("verify: swift test # быстро") && on.contains("custom: 1"))
        #expect(Frontmatter.setting("worktree", to: "", in: on) == about)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-always-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (text, want) in [(about, false), (on, true)] {
            try text.write(to: dir.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
            #expect(Codec.project(at: dir, category: "c").alwaysWorktree == want)
        }
        let url = URL(fileURLWithPath: "/p/tasks/20261123-000000-a.md")
        let t = Codec.task(from: "---\ntitle: \"A\"\nstatus: todo\nworktree: never\n---\n\nx\n", url: url)
        #expect(t.mainFolderOnly)
        #expect(Codec.task(from: Codec.serialize(t), url: url).mainFolderOnly)
    }

    @Test func forcedJobRespectsPauseLimitAndDepends() {
        let dep = job("dep", .running, cwd: "/q")
        var a = job("a", cwd: "/p", depends: [dep]); a.forceWorktree = true
        #expect(started(QueuePlanner.decide(jobs: [dep, a], settings: settings()), [a]).isEmpty)
        a.depends = []
        #expect(started(QueuePlanner.decide(jobs: [a], settings: settings(paused: true)), [a]).isEmpty)
        #expect(started(QueuePlanner.decide(jobs: [a], settings: settings(hold: "x")), [a]).isEmpty)
        #expect(started(QueuePlanner.decide(jobs: [dep, a], settings: settings(limit: 1)), [a]).isEmpty)
    }

    /// An agent that edits code only in a worktree.
    @Test func agentWorktree() {
        var j = QueuePlanner.Job()
        j.agentWorktree = true
        func decide(_ j: QueuePlanner.Job, _ edit: (inout QueuePlanner.Settings) -> Void = { _ in }) -> QueuePlanner.Decision? {
            var s = QueuePlanner.Settings(limit: 3)
            edit(&s)
            return QueuePlanner.decide(jobs: [j], settings: s)[j.id]
        }
        #expect(decide(j) == .needWorktree)
        #expect(QueuePlanner.dirtyCandidates(jobs: [j], settings: .init(limit: 3)) == ["/p"])
        for edit: (inout QueuePlanner.Settings) -> Void in [{ $0.worktreesEnabled = false }, { $0.noCommits = ["/p"] }] {
            guard case .wait(.agentWorktree)? = decide(j, edit) else { Issue.record("must wait"); continue }
        }
        #expect(decide(j) { $0.dirtyFiles = ["/p": ["a.swift"]] } == .wait(.sameFolder(.dirtyMain(["a.swift"]))))
        // «Опасный режим» doesn't skip that question.
        var forced = j
        forced.forceWorktree = true
        #expect(decide(forced) { $0.dirtyFiles = ["/p": ["a.swift"]] } == .wait(.sameFolder(.dirtyMain(["a.swift"]))))
        var planning = j
        planning.lane = .light
        #expect(decide(planning) == .start)
    }

    // MARK: Several repositories

    @Test func groupTakesAllFolders() {
        var g = job("g", cwd: "/p")
        g.extraFolders = ["/api", "/web"]
        func decide(_ jobs: [J], _ s: QueuePlanner.Settings) -> D? { QueuePlanner.decide(jobs: jobs, settings: s)[g.id] }
        var s = QueuePlanner.Settings(limit: 3, dirtyFiles: ["/p": [], "/api": [], "/web": []])
        #expect(QueuePlanner.dirtyCandidates(jobs: [g], settings: s) == ["/p", "/api", "/web"])
        #expect(decide([g], s) == .needWorktree)
        // A task right in the main folder of one of them.
        let other = job("other", .running, cwd: "/web")
        #expect(decide([other, g], s) == .wait(.repos("в основной папке «web» идёт «other»")))
        var isolated = other
        isolated.worktree = "/wt"
        #expect(decide([isolated, g], s) == .needWorktree)
        s.dirtyFiles?["/api"] = ["x.swift"]
        #expect(decide([g], s) == .wait(.sameFolder(.dirtyMain(["api/x.swift"]))))
        var anyway = g
        anyway.allowDirtyMain = true
        #expect(QueuePlanner.decide(jobs: [anyway], settings: s)[g.id] == .needWorktree)
        s.noCommits = ["/web"]
        #expect(decide([g], s) == .wait(.repos("нет git/коммитов в «web»")))
        s.worktreesEnabled = false
        #expect(decide([g], s) == .wait(.repos("worktree выключены в Настройках")))
    }

    @Test func groupSendsOthersToWorktrees() {
        var g = job("g", .running, cwd: "/p")
        g.extraFolders = ["/api"]
        g.worktree = "/wt/g"
        let one = job("one", cwd: "/api")
        let s = QueuePlanner.Settings(limit: 3, dirtyFiles: [:])
        #expect(QueuePlanner.decide(jobs: [g, one], settings: s)[one.id] == .needWorktree)
        #expect(QueuePlanner.dirtyCandidates(jobs: [g, one], settings: s) == ["/api"])
        // Its path may be written differently.
        var aliased = job("aliased", cwd: "/link")
        aliased.realCwd = "/api"
        #expect(QueuePlanner.decide(jobs: [g, aliased], settings: s)[aliased.id] == .needWorktree)
        var main = one
        main.mustUseMain = true
        #expect(QueuePlanner.decide(jobs: [g, main], settings: s)[main.id] == .wait(.sameFolder(.plain)))
        g.state = .done
        #expect(QueuePlanner.decide(jobs: [g, one], settings: s)[one.id] == .start)
    }

    /// Crossing groups don't hold a part each: both go, in their own worktrees.
    @Test func crossingGroups() {
        var a = job("a", cwd: "/p"), b = job("b", cwd: "/api")
        a.extraFolders = ["/api"]
        b.extraFolders = ["/p"]
        let d = QueuePlanner.decide(jobs: [a, b], settings: .init(limit: 3, dirtyFiles: ["/p": [], "/api": []]))
        #expect(d[a.id] == .needWorktree && d[b.id] == .needWorktree)
    }

    @Test func gitOperationHoldsTheMainFolderAndNewWorktrees() {
        func decide(_ j: QueuePlanner.Job) -> QueuePlanner.Decision? {
            var s = QueuePlanner.Settings(limit: 3, dirtyFiles: [:])
            s.gitBusy = ["/p"]
            return QueuePlanner.decide(jobs: [j], settings: s)[j.id]
        }
        #expect(decide(.init()) == .wait(.gitBusy))
        for edit: (inout QueuePlanner.Job) -> Void in [{ $0.alwaysWorktree = true }, { $0.forceWorktree = true }, { $0.agentWorktree = true }] {
            var j = QueuePlanner.Job()
            edit(&j)
            #expect(decide(j) == .wait(.gitBusy))
        }
        // One of the task's other repositories.
        var group = QueuePlanner.Job(cwd: "/other")
        group.extraFolders = ["/p"]
        #expect(decide(group) == .wait(.gitBusy))
        #expect(decide(.init(worktree: "/wt")) == .start)
        #expect(decide(.init(cwd: "/other")) == .start)
    }
}

@Suite("QueuePlanner: порядок по числу разблокируемых")
struct QueueUnblockOrderTests {
    typealias J = QueuePlanner.Job
    func s(_ limit: Int = 1) -> QueuePlanner.Settings { .init(limit: limit, dirtyFiles: ["/p": []]) }
    func job(_ t: String, _ state: QueuePlanner.State = .pending, deps: [J] = [], prio: Int = 1, lane: QueuePlanner.Lane = .code) -> J {
        var j = J(title: t, state: state, lane: lane, cwd: "/p/\(t)", depends: deps.map(\.id)); j.priority = prio; return j
    }
    func started(_ d: [UUID: QueuePlanner.Decision], _ jobs: [J]) -> [String] {
        jobs.filter { d[$0.id] == .start || d[$0.id] == .needWorktree }.map(\.title)
    }

    @Test func transitiveCount() {
        let a = job("a"), b = job("b", deps: [a]), c = job("c", deps: [b]), done = job("d", .done, deps: [a])
        let counts = QueuePlanner.unblockCounts(jobs: [a, b, c, done])
        #expect(counts[a.id] == 2 && counts[b.id] == 1 && counts[c.id] == 0)
    }

    @Test func diamondCountsOnce() {
        let a = job("a"), b = job("b", deps: [a]), c = job("c", deps: [a]), d = job("d", deps: [b, c])
        #expect(QueuePlanner.unblockCounts(jobs: [a, b, c, d])[a.id] == 3)
    }

    @Test func moreUnblockingGoesFirst() {
        let x = job("x"), y = job("y"), z = job("z", deps: [y])
        let jobs = [x, y, z]
        let d = QueuePlanner.decide(jobs: jobs, settings: s())
        #expect(started(d, jobs) == ["y"])
    }

    @Test func tieKeepsQueueOrder() {
        let jobs = [job("x"), job("y"), job("z")]
        #expect(started(QueuePlanner.decide(jobs: jobs, settings: s()), jobs) == ["x"])
    }

    @Test func busySlotsLeaveQueueOrderWhenRoomIsEnough() {
        let r = job("r", .running), x = job("x"), y = job("y"), z = job("z", deps: [y])
        let jobs = [r, x, y, z]
        #expect(started(QueuePlanner.decide(jobs: jobs, settings: s(2)), jobs) == ["y"])
        #expect(started(QueuePlanner.decide(jobs: jobs, settings: s(4)), jobs) == ["x", "y"])
    }

    @Test func differentPrioritiesKeepOrder() {
        let x = job("x", prio: 2), y = job("y", prio: 1), z = job("z", deps: [y], prio: 1)
        let jobs = [x, y, z]
        #expect(started(QueuePlanner.decide(jobs: jobs, settings: s()), jobs) == ["x"])
    }

    @Test func chainKeepsQueueOrder() {
        let a = job("a"), b = job("b", deps: [a]), c = job("c", deps: [b]), d = job("d")
        let jobs = [a, b, c, d]
        #expect(QueuePlanner.walkOrder(jobs, settings: s()) == [0, 1, 2, 3])
        var waves = jobs
        for i in waves.indices { waves[i].wave = i + 1; waves[i].wavePriority = "high" }
        #expect(QueuePlanner.walkOrder(waves, settings: s()) == [0, 1, 2, 3])
        #expect(started(QueuePlanner.decide(jobs: jobs, settings: s()), jobs) == ["a"])
    }

    @Test func fileWaitKeepsPlaceBeforeLater() {
        var run = job("run", .running); run.cwd = "/p"; run.files = ["a.swift"]
        var w1 = job("w1"), w2 = job("w2")
        w1.cwd = "/p"; w1.files = ["a.swift"]; w2.cwd = "/p"; w2.files = ["a.swift"]
        // Equal counts: w1 is first in queue order, so it holds the files before w2.
        var jobs = [run, w1, w2]
        var d = QueuePlanner.decide(jobs: jobs, settings: s(2))
        #expect(d[w1.id] == .wait(.files(["a.swift"], titles: ["run"], unmerged: false)))
        #expect(d[w2.id] == .wait(.files(["a.swift"], titles: ["run", "w1"], unmerged: false)))
        // Early one unblocks more: same result.
        let blocker = job("blk", deps: [w1])
        jobs = [run, w1, w2, blocker]
        d = QueuePlanner.decide(jobs: jobs, settings: s(2))
        #expect(d[w1.id] == .wait(.files(["a.swift"], titles: ["run"], unmerged: false)))
        #expect(d[w2.id] == .wait(.files(["a.swift"], titles: ["run", "w1"], unmerged: false)))
    }

    @Test func sameFilesDoNotOvertake() {
        var run = job("run", .running); run.cwd = "/p"; run.files = ["a.swift"]
        var w1 = job("w1"), w2 = job("w2")
        w1.cwd = "/p"; w1.files = ["a.swift"]; w2.cwd = "/p"; w2.files = ["a.swift/x"]
        let blocker = job("blk", deps: [w2])
        let jobs = [run, w1, w2, blocker]
        #expect(QueuePlanner.walkOrder(jobs, settings: s(2)) == [1, 2, 3])
        let d = QueuePlanner.decide(jobs: jobs, settings: s(2))
        #expect(d[w2.id] == .wait(.files(["a.swift/x"], titles: ["run", "w1"], unmerged: false)))
        // Other files: w2 may go first.
        var w3 = w2; w3.files = ["b.swift"]
        #expect(QueuePlanner.walkOrder([run, w1, w3, blocker], settings: s(2)) == [2, 1, 3])
    }

    @Test func lanesAreCountedSeparately() {
        // Code lane is crowded, light lane has room: the light job order doesn't matter, code job order follows unblocks.
        let c1 = job("c1"), c2 = job("c2"), c3 = job("c3", deps: [c2])
        let l1 = job("l1", lane: .light), l2 = job("l2", lane: .light)
        #expect(QueuePlanner.walkOrder([c1, c2, c3, l1, l2], settings: s(1)).prefix(2) == [1, 0])
        // Nobody is crowded: queue order.
        #expect(QueuePlanner.walkOrder([c1, c2, c3, l1], settings: s(5)) == [0, 1, 2, 3])
        let d = QueuePlanner.decide(jobs: [c1, c2, l1, l2], settings: s(1))
        #expect(d[l1.id] == .start && d[l2.id] == .wait(.slot(limit: 1)))
    }
}
