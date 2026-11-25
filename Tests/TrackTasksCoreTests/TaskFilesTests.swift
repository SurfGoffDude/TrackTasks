import Foundation
import Testing
@testable import TrackTasksCore

@Suite("files: paths")
struct TaskFilesTests {
    @Test func overlap() {
        #expect(TaskFiles.overlap(["Sources/A.swift"], ["sources/a.SWIFT"]) == ["Sources/A.swift"])
        #expect(TaskFiles.overlap(["Sources/"], ["Sources/Core/B.swift"]) == ["Sources/Core/B.swift"])
        #expect(TaskFiles.overlap(["./Sources/Core/B.swift"], ["Sources"]) == ["./Sources/Core/B.swift"])
        #expect(TaskFiles.overlap(["Й.md".decomposedStringWithCanonicalMapping], ["й.md"]).count == 1)
        #expect(TaskFiles.overlap(["Sources/A.swift", "Sources/TrackTasks/"], ["Sources/B.swift", "Sources/TrackTasksCore/"]).isEmpty)
        #expect(TaskFiles.overlap(["../x", "/x"], ["../x", "/x"]).isEmpty)
    }

    @Test func validity() {
        for p in ["a.swift", "./a", "dir/", "app/[id]/page.tsx", "a..b/c"] { #expect(TaskFiles.isValid(p), "\(p)") }
        for p in ["", "/a", "~/a", "../a", "a/../b", ".", "./", "Sources/*.swift"] { #expect(!TaskFiles.isValid(p), "\(p)") }
    }

    @Test func suggestFromPlan() {
        let known = ["Sources/App/Jobs.swift", "Sources/Core/Models.swift", "Sources/App/Models.swift", "README.md", "docs/a.md", "tasks/x.md"]
        let plan = """
            1. `jobs.swift:120-130` и Models.swift: правка.
            2. Новый `Sources/Core/New.swift`, папка `Sources/Core/`, файл README.md.
            3. docs не трогаем, tasks/x.md тоже, см. https://example.com/Sources/App/Jobs.swift и/или `nope/New.swift`.
            """
        #expect(TaskFiles.suggest(plan: plan, known: known)
            == ["Sources/App/Jobs.swift", "Sources/Core/New.swift", "Sources/Core/", "README.md"])
        #expect(TaskFiles.suggest(plan: "", known: known).isEmpty)
    }
}

@Suite("files: task file")
struct TaskFilesFieldTests {
    let url = URL(fileURLWithPath: "/t/20261123-100000-x.md")
    let text = "---\ntitle: \"x\"\nstatus: todo # s\npriority: medium\ncreated: 2026-11-23\ncompleted:\ntags: [q]\nfiles: [Sources/A.swift, app/[id]/] # что\n---\n\nт\n"

    @Test func parseAndInPlaceWrite() {
        var t = Codec.task(from: text, url: url)
        #expect(t.files == ["Sources/A.swift", "app/[id]/"])
        #expect(Codec.serialize(t, updating: text) == text)
        #expect(Codec.task(from: Codec.serialize(t), url: url).files == t.files)
        t.files = ["B.swift"]
        #expect(Codec.serialize(t, updating: text)
            == text.replacingOccurrences(of: "[Sources/A.swift, app/[id]/]", with: "[B.swift]"))
        t.files = []
        #expect(Codec.serialize(t, updating: text)
            == text.replacingOccurrences(of: "files: [Sources/A.swift, app/[id]/] # что\n", with: ""))
    }

    @Test func canonicalRoundTrip() {
        var t = Codec.task(from: text, url: url)
        t.depends = ["a.md"]
        let canonical = Codec.serialize(t)
        #expect(canonical.contains("depends: [a.md]\nfiles: [Sources/A.swift, app/[id]/]\n---"))
        #expect(Codec.serialize(Codec.task(from: canonical, url: url)) == canonical)
    }

    @Test func lint() {
        func problems(_ v: String) -> Int {
            let s = text.replacingOccurrences(of: "[Sources/A.swift, app/[id]/] # что", with: v)
            return TaskLint.fileProblems(text: s, fileName: url.lastPathComponent).filter { $0.kind == .field("files") }.count
        }
        #expect(problems("[Sources/A.swift, Tests/]") == 0)
        #expect(problems("[]") == 0)
        #expect(problems("[../a, /b, c]") == 2)
    }
}

@Suite("QueuePlanner: files")
struct QueuePlannerFilesTests {
    typealias J = QueuePlanner.Job
    typealias D = QueuePlanner.Decision

    func job(_ title: String, _ files: [String], _ state: QueuePlanner.State = .pending, cwd: String = "/p",
             depends: [J] = [], worktree: String? = nil, awaitsMerge: Bool = false) -> J {
        var j = J(title: title, state: state, cwd: cwd, worktree: worktree, depends: depends.map(\.id), awaitsMerge: awaitsMerge)
        j.files = files
        return j
    }

    func decide(_ jobs: [J], limit: Int = 5, dirty: [String] = []) -> [D?] {
        let d = QueuePlanner.decide(jobs: jobs, settings: .init(limit: limit, dirtyFiles: ["/p": dirty]))
        return jobs.map { d[$0.id] }
    }

    @Test func overlapWaits() {
        for (x, y, common) in [("S/A.swift", "s/a.swift", "s/a.swift"), ("S/", "S/A.swift", "S/A.swift"), ("S/A.swift", "S", "S/A.swift")] {
            let d = decide([job("a", [x]), job("b", [y])])
            #expect(d[0] == .start)
            #expect(d[1] == .wait(.files([common], titles: ["a"], unmerged: false)))
        }
    }

    @Test func noOverlapNoFieldOtherProject() {
        #expect(decide([job("a", ["A"]), job("b", ["B"]), job("c", [])]) == [.start, .needWorktree, .needWorktree])
        #expect(decide([job("a", ["A"]), job("b", ["A"], cwd: "/q")]) == [.start, .start])
    }

    @Test func unmergedBranchHolds() {
        var old = job("a", ["S/"], .done, worktree: "/w", awaitsMerge: true)
        #expect(decide([old, job("b", ["S/B"])])[1] == .wait(.files(["S/B"], titles: ["a"], unmerged: true)))
        old.awaitsMerge = false
        #expect(decide([old, job("b", ["S/B"])])[1] == .start)
    }

    @Test func runAnyway() {
        var b = job("b", ["A"])
        b.ignoresFiles = true
        #expect(decide([job("a", ["A"], .running), b])[1] == .needWorktree)
    }

    @Test func startedBranchesDontWaitForEachOther() {
        // Both tasks are done and unmerged; a fix of each must be able to start.
        let a = job("a", ["A"], .done, worktree: "/wa", awaitsMerge: true), b = job("b", ["A"], .done, worktree: "/wb", awaitsMerge: true)
        #expect(Array(decide([a, b, job("fa", ["A"], worktree: "/wa"), job("fb", ["A"], worktree: "/wb")])[2...]) == [.start, .start])
    }

    @Test func dependsBeatsFiles() {
        // «b» was done before its dependency was restarted: its branch can't hold the dependency back.
        let a = job("a", ["A"])
        let mid = job("m", [], .done, depends: [a])
        let b = job("b", ["A"], .done, depends: [mid], worktree: "/wb", awaitsMerge: true)
        #expect(decide([a, mid, b])[0] == .start)
        // Depends in the opposite order of the queue.
        let dep = job("dep", ["A"])
        let first = job("first", ["A"], depends: [dep])
        #expect(decide([first, dep]) == [.wait(.dependencies(["dep"])), .start])
    }

    @Test func queueOrderIsKept() {
        // «b» waits for «a»; «c» must not overtake it by taking B. «d» is independent.
        let jobs = [job("a", ["A"], .running), job("b", ["A", "B"]), job("c", ["B"]), job("d", ["D"])]
        let d = decide(jobs)
        #expect(d[1] == .wait(.files(["A"], titles: ["a"], unmerged: false)))
        #expect(d[2] == .wait(.files(["B"], titles: ["b"], unmerged: false)))
        #expect(d[3] == .needWorktree)
    }

    /// Run everything, merging whatever is done: the queue always gets to the end.
    @Test func noDeadlock() {
        for seed in 0..<40 {
            var jobs = (0..<6).map { i in job("j\(i)", [0, 1, 2].filter { ((seed * 7 + i * 5 + 3) >> $0) & 1 == 1 }.map { "F\($0)" }) }
            if seed % 2 == 0 { jobs[0].depends = [jobs[5].id] }
            if seed % 3 == 0 { jobs[2].depends = [jobs[4].id] }
            for _ in 0..<20 {
                let d = QueuePlanner.decide(jobs: jobs, settings: .init(limit: 3, dirtyFiles: [:]))
                for i in jobs.indices {
                    if jobs[i].state == .running {
                        jobs[i].state = .done
                        jobs[i].awaitsMerge = jobs[i].worktree != nil
                    } else if jobs[i].state == .done {
                        jobs[i].awaitsMerge = false
                    } else if d[jobs[i].id] == .start {
                        jobs[i].state = .running
                    } else if d[jobs[i].id] == .needWorktree {
                        jobs[i].state = .running
                        jobs[i].worktree = "/w\(i)"
                    }
                }
            }
            #expect(jobs.allSatisfy { $0.state == .done }, "seed \(seed)")
        }
    }

    @Test func dirtyMainOnlyCommonFiles() {
        let busy = job("a", ["Z"], .running)
        #expect(decide([busy, job("b", ["S/"])], dirty: ["README.md"])[1] == .needWorktree)
        #expect(decide([busy, job("b", ["S/"])], dirty: ["README.md", "s/x.swift"])[1] == .wait(.sameFolder(.dirtyMain(["s/x.swift"]))))
        #expect(decide([busy, job("b", [])], dirty: ["README.md"])[1] == .wait(.sameFolder(.dirtyMain(["README.md"]))))
        // Only bad paths: same as no field.
        #expect(decide([busy, job("b", ["../x"])], dirty: ["README.md"])[1] == .wait(.sameFolder(.dirtyMain(["README.md"]))))
        // The dependency's work is uncommitted: the job needs all of it.
        var dep = job("dep", ["README.md"], .done)
        dep.doneInMain = true
        #expect(decide([busy, dep, job("b", ["S/"], depends: [dep])], dirty: ["README.md"])[2]
            == .wait(.sameFolder(.dirtyMain(["README.md"]))))
    }

    @Test func reasonText() {
        #expect(QueuePlanner.WaitReason.files(["A.swift"], titles: ["X"], unmerged: true).text
            == "правит те же файлы: A.swift — ждёт слияния «X»")
    }
}
