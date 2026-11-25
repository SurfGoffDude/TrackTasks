import Foundation
import Testing
@testable import TrackTasksCore

@Suite("TaskGraph.build")
struct TaskGraphTests {
    typealias T = TaskGraph.Task

    @Test func wavesAndStates() {
        let tasks = [T(name: "a", status: .todo, priority: .low, depends: ["b"]),
                     T(name: "b", status: .todo, priority: .medium, depends: ["d"]),
                     T(name: "c", status: .todo, priority: .high, depends: []),
                     T(name: "d", status: .done, priority: .high, depends: [])]
        let g = TaskGraph.build(tasks)
        #expect(g.columns.map(\.kind) == [.done, .wave(1, .high), .wave(2, .medium), .wave(3, .low)])
        #expect(g.columns.map(\.tasks) == [["d"], ["c"], ["b"], ["a"]])
        #expect(g.nodes["a"]?.state == .blocked)
        #expect(g.nodes["b"]?.state == .ready)
        #expect(g.nodes["c"]?.state == .ready)
        #expect(g.nodes["d"]?.state == .done)
        #expect(Set(g.edges) == [.init(from: "b", to: "a"), .init(from: "d", to: "b")])
        #expect(g.errors.isEmpty)
    }

    @Test func hideDone() {
        let tasks = [T(name: "a", status: .todo, priority: .medium, depends: ["d"]),
                     T(name: "d", status: .done, priority: .high, depends: [])]
        let g = TaskGraph.build(tasks, showDone: false)
        #expect(g.columns.map(\.tasks) == [["a"]])
        #expect(g.edges.isEmpty)
        #expect(g.nodes["a"]?.state == .ready)
    }

    @Test func cycleIsErrorRestStillLaidOut() {
        let tasks = [T(name: "a", status: .todo, priority: .high, depends: ["b"]),
                     T(name: "b", status: .todo, priority: .high, depends: ["a"]),
                     T(name: "c", status: .todo, priority: .medium, depends: ["a"]),
                     T(name: "e", status: .todo, priority: .low, depends: [])]
        let g = TaskGraph.build(tasks)
        #expect(g.nodes["a"]?.state == .error)
        #expect(g.nodes["b"]?.state == .error)
        #expect(g.nodes["a"]?.errors.first?.hasPrefix("Цикл в depends") == true)
        #expect(g.nodes["c"]?.state == .blocked)
        #expect(g.columns.last == .init(kind: .errors, tasks: ["a", "b"]))
        #expect(g.waves.flatMap(\.tasks) == ["c", "e"])
        #expect(g.errors.count == 1)
    }

    @Test func selfDependencyAndMissingFile() {
        let tasks = [T(name: "a", status: .todo, priority: .high, depends: ["a"]),
                     T(name: "b", status: .todo, priority: .high, depends: ["nope.md"]),
                     T(name: "d", status: .done, priority: .high, depends: ["gone.md"])]
        let g = TaskGraph.build(tasks)
        #expect(g.nodes["a"]?.state == .error)
        #expect(g.nodes["b"]?.state == .error)
        #expect(g.nodes["b"]?.errors == ["b зависит от несуществующей задачи nope.md"])
        #expect(g.nodes["d"]?.state == .error)
        #expect(g.waves.flatMap(\.tasks) == ["b"])
        #expect(g.errors.count == 3)
    }

    @Test func twoCycles() {
        let tasks = [T(name: "a", status: .todo, priority: .high, depends: ["b"]),
                     T(name: "b", status: .todo, priority: .high, depends: ["a"]),
                     T(name: "c", status: .todo, priority: .high, depends: ["d"]),
                     T(name: "d", status: .todo, priority: .high, depends: ["c"])]
        let g = TaskGraph.build(tasks)
        #expect(g.columns.map(\.kind) == [.errors])
        #expect(g.errors.count == 2)
    }

    /// Same waves as «Волнами по приоритету» for all unfinished tasks (Store.enqueue → WavePlan).
    @Test func matchesWavePlanOnThisProject() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        let items = Codec.tasks(in: dir.appendingPathComponent("tasks"))
        try #require(!items.isEmpty)
        let byName = Dictionary(items.map { ($0.fileName, $0) }, uniquingKeysWith: { a, _ in a })
        let nodes = byName.mapValues { DependencyPlan.Node(done: $0.status == .done, depends: $0.depends) }
        let targets = items.filter { $0.status != .done }.map(\.fileName)
        let expected = WavePlan.waves(targets: targets, nodes: nodes, priority: byName.mapValues(\.priority))
        let g = TaskGraph.build(items.map(TaskGraph.Task.init))
        if case .success(let w) = expected {
            #expect(g.waves == w)
            #expect(g.errors.isEmpty)
        } else {
            #expect(!g.errors.isEmpty)
        }
    }

    @Test func fiftyTasksFast() {
        let prios: [Priority] = [.high, .medium, .low]
        let tasks = (0..<50).map { i in
            T(name: "t\(i)", status: i % 7 == 0 ? .done : .todo, priority: prios[i % 3],
              depends: i == 0 ? [] : ["t\(i / 2)", "t\(i - 1)"])
        }
        let start = Date()
        let g = TaskGraph.build(tasks)
        #expect(Date().timeIntervalSince(start) < 0.1)
        #expect(g.errors.isEmpty)
        #expect(g.columns.flatMap(\.tasks).count == 50)
    }
}
