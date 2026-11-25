import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

@MainActor struct EvidencePromptTests {
    private func job() -> Job {
        Job(kind: .runTask, title: "x", projectID: nil, projectName: "p", cwd: URL(fileURLWithPath: "/tmp/p"),
            prompt: "x", systemPrompt: "", taskPath: "/tmp/p/tasks/x.md")
    }

    @Test func queuePromptAsksForEveryCriterion() {
        let rule = "Под каждым отмеченным [x] пунктом «Критериев готовности» напиши вложенную строку «  - Доказательство: …»"
        let t = TaskItem(url: URL(fileURLWithPath: "/tmp/p/tasks/x.md"), title: "x", status: .todo, priority: .low,
                         created: "", completed: "", body: "")
        for p in [ClaudePrompts.runTask(t), ClaudePrompts.codingSystem(name: "p", path: "/tmp/p"), ClaudePrompts.fix(task: job())] {
            #expect(p.contains(rule) && p.contains("Результаты не выдумывай"))
        }
        #expect(ClaudePrompts.review(task: job()).contains("«Доказательство» под ним — слова исполнителя"))
        #expect(!ClaudePrompts.planSystem.contains("Доказательство"))
    }

    /// The example of the format is read by the parser.
    @Test func formatExampleParses() {
        let c = MD.checklist(ClaudePrompts.taskFormat, in: .criteria)
        #expect(c.count == 1 && c[0].evidence.hasPrefix("команда"))
    }

    @Test func flagSurvivesAndOldRecordHasNone() throws {
        let j = job()
        j.evidenceAsked = true
        let data = try JSONEncoder().encode(j.record)
        #expect(Job(try JSONDecoder().decode(JobRecord.self, from: data)).evidenceAsked)
        var o = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(o.removeValue(forKey: "evidenceAsked") != nil)
        let old = try JSONDecoder().decode(JobRecord.self, from: JSONSerialization.data(withJSONObject: o))
        #expect(!Job(old).evidenceAsked)
    }

    @Test func checkComesFromTheRunOnly() {
        let q = JobQueue(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("tt-ev-\(UUID().uuidString).json"),
                         agents: AgentRegistry([FakeAgent()]), recordSpend: { _, _, _, _ in })
        let j = job()
        j.state = .done
        #expect(q.trackerCheck(j) == .notRun(""))
        j.verifyNote = JobQueue.taskCheckApproved
        j.verifyFailed = true
        #expect(q.trackerCheck(j) == .notRun(JobQueue.taskCheckApproved))
        j.verifyNote = Evidence.passedMark + "true"
        j.verifyFailed = false
        #expect(q.trackerCheck(j) == .passed(j.verifyNote))
        j.state = .running
        #expect(q.trackerCheck(j) == .working)
    }
}
