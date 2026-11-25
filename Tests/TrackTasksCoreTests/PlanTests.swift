import Foundation
import Testing
@testable import TrackTasksCore

@Suite("План до кода")
struct PlanTests {
    static let withPlan = """
        Описание.

        - [ ] шаг задачи

        ## План
        1. Прочитать код
        - [ ] пункт плана с чекбоксом
        2. Поправить

        ## Критерии готовности
        - [ ] критерий
        """

    @Test func planCheckboxesAreNotSteps() {
        #expect(MD.checklist(Self.withPlan).map(\.text) == ["шаг задачи"])
        #expect(MD.checklist(Self.withPlan, in: .criteria).map(\.text) == ["критерий"])
    }

    @Test func planTextAndDescription() {
        #expect(MD.plan(Self.withPlan).hasPrefix("1. Прочитать код"))
        #expect(MD.plan(Self.withPlan).hasSuffix("2. Поправить"))
        #expect(MD.plan("Просто описание") == "")
        let d = MD.withoutTasks(Self.withPlan)
        #expect(d == "Описание.")
    }

    @Test func appendedStepGoesBeforePlan() {
        let t = MD.appendTask(Self.withPlan, "новый")
        #expect(MD.checklist(t).map(\.text) == ["шаг задачи", "новый"])
    }

    @Test func planFlagParsedAndRoundTrips() {
        let url = URL(fileURLWithPath: "/t/a.md")
        let text = "---\ntitle: x\nstatus: todo\npriority: low\ncreated: 2026-11-23\ncompleted:\nplan: true\n---\n\nтело\n"
        var t = Codec.task(from: text, url: url)
        #expect(t.plan)
        #expect(Codec.serialize(t, updating: text) == text)
        t.plan = false
        let off = Codec.serialize(t, updating: text)
        #expect(!off.contains("plan:"))
        #expect(!Codec.task(from: off, url: url).plan)
        t.plan = true
        #expect(Codec.task(from: Codec.serialize(t), url: url).plan)
        #expect(!Codec.task(from: "---\ntitle: x\n---\n", url: url).plan)
    }

    // MARK: Planner

    typealias J = QueuePlanner.Job

    @Test func awaitingPlanWaitsAndTakesNoSlot() {
        let a = J(title: "a", state: .pending, cwd: "/p", awaitingPlan: true)
        let b = J(title: "b", state: .pending, cwd: "/p")
        let c = J(title: "c", state: .pending, cwd: "/p2")
        let d = QueuePlanner.decide(jobs: [a, b, c], settings: .init(limit: 1, dirtyFiles: [:]))
        #expect(d[a.id] == .wait(.planApproval))
        // The only slot is free for the others; a doesn't hold /p either.
        #expect(d[b.id] == .start)
        #expect(d[c.id] == .wait(.slot(limit: 1)))
        #expect(QueuePlanner.WaitReason.planApproval.text == "ждёт одобрения плана")
    }

    @Test func awaitingPlanIgnoresPauseAndDependentsWait() {
        let a = J(title: "a", state: .pending, awaitingPlan: true)
        let dep = J(title: "dep", state: .pending, depends: [a.id])
        let d = QueuePlanner.decide(jobs: [a, dep], settings: .init(limit: 3, paused: true))
        #expect(d[a.id] == .wait(.planApproval))
        let d2 = QueuePlanner.decide(jobs: [a, dep], settings: .init(limit: 3))
        #expect(d2[dep.id] == .wait(.dependencies(["a"])))
    }

    @Test func awaitingPlanDoesNotBusyTheMainFolder() {
        let a = J(title: "a", state: .pending, cwd: "/p", awaitingPlan: true)
        let b = J(title: "b", state: .pending, cwd: "/p")
        #expect(QueuePlanner.dirtyCandidates(jobs: [a, b], settings: .init(limit: 3)).isEmpty)
        // …and an approved one starts in main, since nothing else runs there.
        let d = QueuePlanner.decide(jobs: [J(title: "a", state: .pending, cwd: "/p"), b], settings: .init(limit: 3, dirtyFiles: [:]))
        #expect(d.values.contains(.needWorktree))
    }

    @Test func onlyExactPlanHeading() {
        let t = "## План выполнения миграции\n- [ ] шаг\n"
        #expect(MD.checklist(t).map(\.text) == ["шаг"])
    }

    // MARK: Flow

    typealias F = PlanFlow

    @Test func approveAndReworkTransitions() {
        #expect(F.approve(.awaiting) == .approved)
        #expect(F.approve(.planning) == nil)
        #expect(F.approve(.approved) == nil)
        #expect(F.approve(nil) == nil)
        #expect(F.rework(.awaiting, comment: "  короче \n")?.feedback == "короче")
        #expect(F.rework(.awaiting, comment: "  \n")?.phase == nil)
        #expect(F.rework(.approved, comment: "x") == nil)
        #expect(F.rework(.awaiting, comment: "x")?.phase == .planning)
    }

    @Test func approvedRunContinuesPlanSession() {
        #expect(F.resumesPlanSession(.approved, inMainFolder: true))
        #expect(!F.resumesPlanSession(.approved, inMainFolder: false))
        #expect(!F.resumesPlanSession(.planning, inMainFolder: true))
        #expect(!F.resumesPlanSession(.awaiting, inMainFolder: true))
        #expect(!F.resumesPlanSession(nil, inMainFolder: true))
    }

    @Test func afterRunChecks() {
        #expect(F.afterRun(hasPlan: true, before: "a", after: "a", unreliable: false) == .awaitApproval)
        // Baseline missing is an error, not a skipped check.
        #expect(F.afterRun(hasPlan: true, before: nil, after: "a", unreliable: false) != .awaitApproval)
        if case .failed(let m) = F.afterRun(hasPlan: true, before: "a", after: "b", unreliable: false) {
            #expect(m.contains("изменил код"))
        } else { Issue.record("code change must fail") }
        // Another job in the same folder: the comparison means nothing.
        #expect(F.afterRun(hasPlan: true, before: "a", after: "b", unreliable: true) == .awaitApproval)
        #expect(F.afterRun(hasPlan: true, before: F.noGit, after: nil, unreliable: false) == .awaitApproval)
        #expect(F.afterRun(hasPlan: false, before: "a", after: "a", unreliable: false)
                == .failed("Агент не записал «## План» в файл задачи"))
    }

    @Test func phaseSurvivesQueueJSON() throws {
        struct Rec: Codable, Equatable { var planPhase: PlanFlow.Phase?; var planFeedback: String? }
        for p in [PlanFlow.Phase.planning, .awaiting, .approved] {
            let r = Rec(planPhase: p, planFeedback: "к")
            #expect(try JSONDecoder().decode(Rec.self, from: JSONEncoder().encode(r)) == r)
        }
        // Old queue.json without the fields.
        #expect(try JSONDecoder().decode(Rec.self, from: Data("{}".utf8)) == Rec(planPhase: nil, planFeedback: nil))
    }
}
