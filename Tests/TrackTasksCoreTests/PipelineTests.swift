import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct PipelineTests {
    private func state(_ edit: (inout Workflow) -> Void = { _ in }) -> PipelineState {
        var w = Workflow.template
        edit(&w)
        return PipelineState(name: "x", workflow: w)
    }
    private func run(_ s: inout PipelineState, _ events: Pipeline.Event...) -> Pipeline.Action {
        var a = Pipeline.Action.none
        for e in events { a = Pipeline.next(&s, e) }
        return a
    }

    @Test func wholeWay() {
        var s = state()
        #expect(run(&s, .begin) == .start(0))
        if case .gate = run(&s, .succeeded) {} else { Issue.record("план не остановлен") }
        #expect(run(&s, .userContinue) == .start(1))
        #expect(run(&s, .succeeded) == .start(2))
        #expect(run(&s, .verdict(ok: false)) == .start(3))
        #expect(run(&s, .succeeded) == .start(2))
        #expect(run(&s, .verdict(ok: true)) == .finished)
        #expect(!s.isOpen && s.visits == [1, 1, 2, 1])
        #expect(run(&s, .succeeded) == .none && run(&s, .userRepeat) == .none)
    }

    @Test func repeatsEndWithAStop() {
        var s = state()
        _ = run(&s, .begin, .succeeded, .userContinue, .succeeded)
        for _ in 0..<2 { #expect(run(&s, .verdict(ok: false), .succeeded) == .start(2)) }
        _ = run(&s, .verdict(ok: false))
        #expect(s.gate?.kind == .limit && s.visits[3] == 2)
        #expect(run(&s, .userContinue) == .start(3))
    }

    @Test func ceiling() {
        var s = state()
        s.visits = [1, 9, 10, 10]
        s.status = .running
        _ = run(&s, .succeeded)
        s.status = .running; s.current = 1
        _ = run(&s, .succeeded)
        #expect(s.gate?.kind == .limit && s.gate?.reason.contains("30") == true)
    }

    @Test func budget() {
        var s = state { $0.budget = 1 }
        _ = run(&s, .begin)
        s.cost.add(nil)
        _ = run(&s, .succeeded)
        #expect(run(&s, .userContinue) == .start(1))
        #expect(!s.overBudget && s.costText == "нет данных из $1.00")
        s.cost.add(1)
        _ = run(&s, .succeeded)
        #expect(s.gate?.kind == .limit && s.costText?.hasPrefix("≥ $1.00") == true)
        #expect(run(&s, .userContinue) == .start(2))
        #expect(s.restarted().cost == s.cost && s.restarted().status == .ready)
    }

    @Test func troublesWaitForThePerson() {
        for e in [Pipeline.Event.failed("x"), .verifyRed, .nothingChanged, .tampered, .verdict(ok: nil), .changedOutside] {
            var s = state()
            _ = run(&s, .begin, .succeeded, .userContinue, .succeeded)
            _ = run(&s, e)
            #expect(s.gate?.kind == .trouble, "\(e)")
            #expect(run(&s, .userRepeat) == .start(2))
        }
        var s = state()
        _ = run(&s, .begin, .succeeded, .userContinue)
        _ = run(&s, .nothingChanged)
        #expect(run(&s, .userContinue) == .none && s.isOpen)
        // Remarks with nowhere to go.
        s = state { $0.steps[2].onIssues = "" }
        _ = run(&s, .begin, .succeeded, .userContinue, .succeeded, .verdict(ok: false))
        #expect(s.gate != nil)
        #expect(run(&s, .userContinue) == .finished)
    }

    @Test func changeAfterTheEndReopens() {
        var s = state()
        _ = run(&s, .begin, .succeeded, .userContinue, .succeeded, .verdict(ok: true), .changedOutside)
        #expect(s.isOpen && s.gate?.next == .end)
        #expect(run(&s, .userContinue) == .finished)
    }

    @Test func stops() {
        var s = state { $0.steps[0].stop = Workflow.Stop.none; $0.steps[1].stop = .before; $0.budget = 1 }
        _ = run(&s, .begin)
        s.cost.add(2)
        _ = run(&s, .succeeded)
        #expect(s.gate?.kind == .limit)
        _ = run(&s, .userContinue)
        #expect(s.gate?.kind == .before)
        #expect(run(&s, .userContinue) == .start(1))
        #expect(run(&s, .userFinish) == .none)
    }

    @Test func questionsStopTheCodeStep() {
        var s = state()
        _ = run(&s, .begin, .succeeded, .userContinue, .questions(changed: true))
        #expect(s.gate?.reason == "ждёт ответов" && s.gate?.next == .step(2))
        _ = run(&s, .answered)
        #expect(s.gate?.reason == "Агент получил ответы" && s.gate?.next == .step(2))
        #expect(run(&s, .answered) == .none && run(&s, .userContinue) == .start(2))
        var empty = state()
        _ = run(&empty, .begin, .succeeded, .userContinue, .questions(changed: false))
        #expect(empty.gate?.next == nil && run(&empty, .userRepeat) == .start(1))
    }

    @Test func stateSurvivesJSON() throws {
        var s = state()
        _ = run(&s, .begin, .succeeded)
        s.cost.add(nil)
        #expect(try JSONDecoder().decode(PipelineState.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func strictVerdict() {
        #expect(Pipeline.verdict("ВЕРДИКТ: ОК\nвсё хорошо") == true)
        #expect(Pipeline.verdict("\n**ВЕРДИКТ: OK**") == true)
        #expect(Pipeline.verdict("ВЕРДИКТ: ПРАВКИ\n- …") == false)
        for t in ["", "Вот ревью.\nВЕРДИКТ: ОК", "ВЕРДИКТ: ОК, но есть критичное", "готово"] { #expect(Pipeline.verdict(t) == nil) }
    }

    @Test func plannerHoldsAStoppedPipeline() {
        var j = QueuePlanner.Job()
        j.pipelineStop = "бюджет"
        let d = QueuePlanner.decide(jobs: [j], settings: .init(limit: 3))
        #expect(d[j.id] == .wait(.pipeline("бюджет")))
    }
}
