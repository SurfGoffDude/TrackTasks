import Testing
@testable import TrackTasksCore

@Suite("DependencyPlan.order")
struct DependencyPlanTests {
    typealias N = DependencyPlan.Node

    @Test func dependenciesComeFirst() {
        let nodes = ["a": N(done: false, depends: ["b", "c"]), "b": N(done: false, depends: ["c"]),
                     "c": N(done: false, depends: [])]
        #expect(DependencyPlan.order(targets: ["a"], nodes: nodes) == .success(["c", "b", "a"]))
    }

    @Test func doneAndQueuedAreSkipped() {
        let nodes = ["a": N(done: false, depends: ["b", "c", "d"]), "b": N(done: true, depends: ["x"]),
                     "c": N(done: false, depends: ["e"]), "d": N(done: false, depends: []),
                     "e": N(done: false, depends: [])]
        // b is done (its broken dependency x isn't checked), c is queued (not traversed).
        #expect(DependencyPlan.order(targets: ["a"], nodes: nodes, queued: ["c"]) == .success(["d", "a"]))
    }

    @Test func targetOrderKeptWhenIndependent() {
        let nodes = ["a": N(done: false, depends: []), "b": N(done: false, depends: []),
                     "c": N(done: false, depends: ["a"])]
        #expect(DependencyPlan.order(targets: ["b", "c", "a"], nodes: nodes) == .success(["b", "a", "c"]))
    }

    @Test func sharedDependencyAddedOnce() {
        let nodes = ["a": N(done: false, depends: ["c"]), "b": N(done: false, depends: ["c"]),
                     "c": N(done: false, depends: [])]
        #expect(DependencyPlan.order(targets: ["a", "b"], nodes: nodes) == .success(["c", "a", "b"]))
    }

    @Test func twoNodeCycle() {
        let nodes = ["a": N(done: false, depends: ["b"]), "b": N(done: false, depends: ["a"])]
        #expect(DependencyPlan.order(targets: ["a"], nodes: nodes) == .failure(.cycle(["a", "b", "a"])))
    }

    @Test func selfAndDeepCycle() {
        #expect(DependencyPlan.order(targets: ["a"], nodes: ["a": N(done: false, depends: ["a"])])
                == .failure(.cycle(["a", "a"])))
        let nodes = ["x": N(done: false, depends: ["a"]), "a": N(done: false, depends: ["b"]),
                     "b": N(done: false, depends: ["c"]), "c": N(done: false, depends: ["a"])]
        #expect(DependencyPlan.order(targets: ["x"], nodes: nodes) == .failure(.cycle(["a", "b", "c", "a"])))
    }

    @Test func cycleThroughDoneTaskIsIgnored() {
        let nodes = ["a": N(done: false, depends: ["b"]), "b": N(done: true, depends: ["a"])]
        #expect(DependencyPlan.order(targets: ["a"], nodes: nodes) == .success(["a"]))
    }

    @Test func missingDependency() {
        let nodes = ["a": N(done: false, depends: ["b"]), "b": N(done: false, depends: ["ghost.md"])]
        #expect(DependencyPlan.order(targets: ["a"], nodes: nodes)
                == .failure(.missing(task: "b", dependency: "ghost.md")))
    }

    @Test func messages() {
        #expect(DependencyPlan.Failure.cycle(["a", "b", "a"]).message.contains("a → b → a"))
        #expect(DependencyPlan.Failure.missing(task: "a", dependency: "b").message.contains("b"))
    }
}
