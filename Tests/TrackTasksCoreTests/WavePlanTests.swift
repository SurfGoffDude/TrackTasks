import Testing
@testable import TrackTasksCore

@Suite("WavePlan.waves")
struct WavePlanTests {
    typealias N = DependencyPlan.Node
    typealias W = WavePlan.Wave

    @Test func onlyPriorities() {
        let nodes = ["h1": N(done: false, depends: []), "h2": N(done: false, depends: []),
                     "m1": N(done: false, depends: []), "m2": N(done: false, depends: []),
                     "l1": N(done: false, depends: [])]
        let prio: [String: Priority] = ["h1": .high, "h2": .high, "m1": .medium, "m2": .medium, "l1": .low]
        let r = WavePlan.waves(targets: ["m1", "h1", "l1", "h2", "m2"], nodes: nodes, priority: prio)
        #expect(r == .success([W(priority: .high, tasks: ["h1", "h2"]),
                               W(priority: .medium, tasks: ["m1", "m2"]),
                               W(priority: .low, tasks: ["l1"])]))
    }

    @Test func emptyWavesSkipped() {
        let nodes = ["h": N(done: false, depends: []), "l": N(done: false, depends: [])]
        let r = WavePlan.waves(targets: ["h", "l"], nodes: nodes, priority: ["h": .high, "l": .low])
        #expect(r == .success([W(priority: .high, tasks: ["h"]), W(priority: .low, tasks: ["l"])]))
    }

    @Test func dependsInsideWave() {
        let nodes = ["a": N(done: false, depends: ["b"]), "b": N(done: false, depends: []),
                     "c": N(done: false, depends: [])]
        let r = WavePlan.waves(targets: ["a", "b", "c"], nodes: nodes,
                               priority: ["a": .high, "b": .high, "c": .medium])
        // b before a in the same wave; the job of a waits for b.
        #expect(r == .success([W(priority: .high, tasks: ["b", "a"]), W(priority: .medium, tasks: ["c"])]))
    }

    @Test func lowDependencyPulledIntoHighWave() {
        let nodes = ["h": N(done: false, depends: ["m"]), "m": N(done: false, depends: ["l"]),
                     "l": N(done: false, depends: []), "x": N(done: false, depends: [])]
        let r = WavePlan.waves(targets: ["h", "x"], nodes: nodes,
                               priority: ["h": .high, "m": .medium, "l": .low, "x": .low])
        // Transitive: l and m move up to high; x stays low.
        #expect(r == .success([W(priority: .high, tasks: ["l", "m", "h"]), W(priority: .low, tasks: ["x"])]))
    }

    @Test func dependentNeverMovesEarlier() {
        let nodes = ["l": N(done: false, depends: ["h"]), "h": N(done: false, depends: [])]
        let r = WavePlan.waves(targets: ["l", "h"], nodes: nodes, priority: ["l": .low, "h": .high])
        #expect(r == .success([W(priority: .high, tasks: ["h"]), W(priority: .low, tasks: ["l"])]))
    }

    @Test func cycleIsError() {
        let nodes = ["a": N(done: false, depends: ["b"]), "b": N(done: false, depends: ["a"])]
        let r = WavePlan.waves(targets: ["a"], nodes: nodes, priority: ["a": .high, "b": .low])
        #expect(r == .failure(.cycle(["a", "b", "a"])))
    }

    @Test func doneAndQueuedSkipped() {
        let nodes = ["a": N(done: false, depends: ["b", "c"]), "b": N(done: true, depends: []),
                     "c": N(done: false, depends: [])]
        let r = WavePlan.waves(targets: ["a"], nodes: nodes, priority: ["a": .medium, "c": .low], queued: ["c"])
        #expect(r == .success([W(priority: .medium, tasks: ["a"])]))
    }
}
