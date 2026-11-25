import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct WorkflowTests {
    static let text = """
    ---
    title: "Мой"
    budget: 5
    owner: me # моё
    ---

    Вступление.

    ## План
    - type: plan
    - agent: claude

    ## Код
    - type: code
    - agent: codex
    - colour: red

    Делай аккуратно.
    - note: это текст
    ```
    ## не шаг
    ```

    ## Ревью
    - type: review
    - next: end
    - on_issues: Исправление

    ## Исправление
    - type: fix
    - next: ревью
    - repeats: 2
    """
    private func errors(_ text: String) -> [String] {
        guard let p = Workflow.parse(text) else { return ["nil"] }
        return (p.problems + p.workflow.lint()).filter(\.isError).map(\.message)
    }
    /// Steps as "title|field: value|…".
    private func flow(_ steps: String..., head: String = "") -> String {
        "---\n\(head)\n---\n" + steps.map { s in
            let p = s.components(separatedBy: "|")
            return "\n## \(p[0])\n" + p.dropFirst().map { "- \($0)\n" }.joined()
        }.joined()
    }

    @Test func parses() throws {
        let p = try #require(Workflow.parse(Self.text)), w = p.workflow
        #expect(w.title == "Мой" && w.budget == 5 && w.steps.map(\.type) == [.plan, .code, .review, .fix])
        #expect(w.steps[0].stops == .after && w.steps[1].stops == .none && w.steps[1].agent == "codex")
        #expect(w.steps[1].text.hasPrefix("Делай") && w.steps[1].text.contains("- note:") && w.steps[1].text.contains("## не шаг"))
        #expect(w.next(after: 0) == .step(1) && w.next(after: 2) == .end && w.next(after: 3) == .step(2) && w.onIssues(2) == .step(3))
        #expect(errors(Self.text).isEmpty)
        #expect(p.problems.map(\.isError) == [false])
    }

    @Test func writingKeepsUnknown() throws {
        var w = try #require(Workflow.parse(Self.text)).workflow
        w.steps[1].model = "gpt"
        w.budget = nil
        let out = w.serialized(updating: Self.text)
        #expect(out.contains("owner: me # моё") && out.contains("Вступление.") && out.contains("- colour: red") && !out.contains("budget"))
        #expect(Workflow.parse(out)?.workflow == w)
        #expect(w.serialized(updating: out) == out)
        #expect(Workflow.parse(Workflow.template.serialized())?.workflow == Workflow.template)
        #expect(Workflow.template.lint().isEmpty)
    }

    @Test func foreignFilesAreNotPipelines() {
        #expect(Workflow.parse("# CI\n\n## Build\n- run: make\n") == nil)
        #expect(Workflow.parse("") == nil)
    }

    @Test func unlimitedCycleIsRejected() {
        let no = errors(flow("К|type: code", "Р|type: review|next: end|on_issues: И", "И|type: fix|next: Р"))
        #expect(no.count == 1 && no[0].contains("Цикл без лимита"))
        #expect(errors(flow("К|type: code", "Р|type: review|next: end|on_issues: И", "И|type: fix|next: Р|repeats: 1")).isEmpty)
        #expect(errors(flow("К|type: code", "Р|type: review|next: Р")).contains { $0.contains("Цикл без лимита") })
        #expect(errors(flow("П|type: plan|next: П", "К|type: code")).contains { $0.contains("Цикл без лимита") })
        // Two cycles, only one limited.
        #expect(errors(flow("К|type: code", "Р|type: review|next: Р2|on_issues: И", "И|type: fix|next: Р|repeats: 2",
                            "Р2|type: review|next: end|on_issues: И2", "И2|type: fix|next: Р2")).contains { $0.contains("Р2") && $0.contains("Цикл") })
        #expect(errors(flow("К|type: code", "Р|type: review|next: end|on_issues: И", "И|type: fix|next: Р|repeats: 99")).count >= 1)
    }

    @Test(arguments: [
        ("Р|type: review", "Нет шага code"), ("К|type: merge", "сливает всегда человек"), ("К|type: deploy", "допустимо plan"),
        ("К|type: code|next: Нет", "нет шага"), ("К|type: code|on_issues: К", "только у review"), ("К|type: code|agent: Не то", "имя профиля"),
        ("К|type: code|stop: maybe", "допустимо before"), ("К|type: code|repeats: 0", "от 1 до 10"), ("К|type: code|type: fix", "дважды"),
        ("end|type: code", "занято"), ("К|agent: x|type: code|next: merge", "нет шага"),
    ]) func errorInStep(step: String, message: String) {
        #expect(errors(flow(step)).contains { $0.contains(message) })
    }

    @Test func errorsInGraph() {
        #expect(errors(flow("К|type: code", "И|type: fix")).contains { $0.contains("без предшествующего review") })
        #expect(errors(flow("К|type: code|next: end", "Р|type: review")).contains { $0.contains("недостижим") })
        #expect(errors(flow("К|type: code", "к|type: review")).contains { $0.contains("Дубль") })
        #expect(errors(flow("К|type: code", "Р|type: review", "И|type: fix|repeats: 1")).contains { $0.contains("«ОК» ведёт") })
        #expect(errors(flow("К|type: code", "Р|type: review|on_issues: end")).contains { $0.contains("on_issues не может") })
        for b in ["0", "-1", "много", "inf", "nan"] { #expect(errors(flow("К|type: code", head: "budget: \(b)")).contains { $0.contains("budget") }) }
    }

    @Test func machineWarnings() {
        var w = Workflow.template
        w.steps[1].agent = "codex"
        w.steps[2].agent = "gone"
        w.budget = 1
        let out = w.warnings { ["": true, "codex": false][$0] }
        #expect(out.count == 2 && out.allSatisfy { !$0.isError })
    }

    @Test func folderOfTheProject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-wf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wf = dir.appendingPathComponent("workflows/sub")
        try FileManager.default.createDirectory(at: wf, withIntermediateDirectories: true)
        try Self.text.write(to: WorkflowFile.url("a", in: dir), atomically: true, encoding: .utf8)
        try Self.text.write(to: wf.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "# README".write(to: WorkflowFile.url("readme", in: dir), atomically: true, encoding: .utf8)
        #expect(WorkflowFile.all(in: dir).map(\.name) == ["a"])
        #expect(Codec.project(at: dir, category: "x").workflows.count == 1)
        #expect(!DirtyFiles.isTrackerFile("workflows/a.md"))
        #expect(WorkflowFile(url: dir.appendingPathComponent("Плохое имя.md"), text: Self.text)?.errors.count == 1)
    }

    @Test func taskField() {
        let url = URL(fileURLWithPath: "/p/tasks/20261124-000000-x.md")
        let text = "---\ntitle: \"x\"\nstatus: todo\npriority: low\ncreated: 2026-11-24\ncompleted:\nworkflow: main # мой\n---\n\nтекст\n"
        var t = Codec.task(from: text, url: url)
        #expect(t.workflow == "main" && t.problems.isEmpty)
        #expect(Codec.serialize(t, updating: text) == text)
        #expect(Codec.task(from: Codec.serialize(t), url: url).workflow == "main")
        t.workflow = "other"
        #expect(Codec.serialize(t, updating: text).contains("workflow: other # мой"))
        t.workflow = ""
        #expect(!Codec.serialize(t, updating: text).contains("workflow"))
        #expect(!TaskLint.fileProblems(text: text.replacingOccurrences(of: "main", with: "../x"), fileName: url.lastPathComponent).isEmpty)
    }
}
