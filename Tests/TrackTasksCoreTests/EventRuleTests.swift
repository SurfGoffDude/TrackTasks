import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct EventRuleTests {
    let url = URL(fileURLWithPath: "/p/automations/a.md")
    private func rule(_ lines: String, body: String = "Текст") -> EventRule {
        EventRule.parse("---\ntitle: \"Т\"\nenabled: true\n\(lines)\n---\n\n\(body)\n", url: url)
    }
    private func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: Rule

    @Test func parsing() {
        let r = rule("on: github\nevents: [push, issues.opened]\nbranches: [main]\nfields: [issue.title]\nlimit: 5\nqueue: true")
        #expect(r.errors.isEmpty && r.isActive && r.kind == .github && r.limit == 5 && r.queue && r.events == ["push", "issues.opened"])
        #expect(rule("on: webhook").limit == 10)
        for k in EventRule.Kind.allCases { #expect(EventRule.parse(EventRule.template(title: "x", kind: k), url: url).errors.isEmpty) }
        for bad in ["on: smtp", "on: github", "on: github\nevents: [fork]", "on: github\nevents: [issues.]", "on: webhook\nlimit: 61", "on: webhook\nlimit: 0",
                    "on: webhook\nfields: [a..b]", "on: webhook\nfields: [$(x)]", "on: git\nfields: [a]", "on: webhook\nevents: [push]",
                    "on: webhook\nbranches: [main]", "on: webhook\nschedule: daily\ntime: \"09:00\""] {
            #expect(!rule(bad).errors.isEmpty && !rule(bad).isActive, "\(bad)")
        }
    }

    @Test func oneFileIsOneAutomation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-er-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Automation.dir(in: dir)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try json("---\ntitle: x\nenabled: true\non: webhook\n---\n").write(to: a.appendingPathComponent("rule.md"))
        try json("---\ntitle: x\nenabled: true\nschedule: daily\ntime: \"09:00\"\n---\n").write(to: a.appendingPathComponent("sched.md"))
        try json("---\ntitle: x\nenabled: true\non: git\nschedule: daily\ntime: \"09:00\"\n---\n").write(to: a.appendingPathComponent("both.md"))
        try json("# doc\n").write(to: a.appendingPathComponent("doc.md"))
        let p = Codec.project(at: dir, category: "c")
        #expect(p.automations.map(\.fileName) == ["sched.md"])
        #expect(p.eventRules.map(\.fileName) == ["both.md", "rule.md"] && p.eventRules.filter(\.isActive).map(\.fileName) == ["rule.md"])
    }

    @Test func fingerprintIgnoresOnlyTheSwitch() {
        let on = "---\ntitle: x\nenabled: true\non: webhook\n---\n"
        func fp(_ s: String) -> String { EventRule.parse(s, url: url).fingerprint }
        #expect(fp(on) == fp(on.replacingOccurrences(of: "true", with: "false")))
        #expect(fp(on) != fp(on + "x"))
    }

    // MARK: Signature

    @Test func githubSignature() {
        let body = json("{\"a\":1}")
        let s = EventSignature.sign(body, secret: "k")
        #expect(EventSignature.github(s, body: body, secret: "k"))
        for (sig, b, k) in [(s, body, "other"), (s, json("{\"a\":2}"), "k"), (String(s.dropLast()), body, "k"), (String(s.dropFirst(7)), body, "k"),
                            (s.replacingOccurrences(of: "sha256", with: "sha1"), body, "k"), (s + "00", body, "k"), ("", body, "k"),
                            ("sha256=" + String(repeating: "z", count: 64), body, "k")] {
            #expect(!EventSignature.github(sig, body: b, secret: k))
        }
        #expect(!EventSignature.github(nil, body: body, secret: "k"))
        #expect(!EventSignature.github(EventSignature.sign(body, secret: ""), body: body, secret: ""))
        // Known vector of GitHub's documentation.
        #expect(EventSignature.sign(json("Hello, World!"), secret: "It's a Secret to Everybody")
                == "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17")
    }

    @Test func webhookSignature() {
        let body = json("{}"), nonce = "0123456789abcdef", now = Date(timeIntervalSince1970: 1_800_000_000)
        func check(time: String = "1800000000", nonce n: String? = nil, sig: String? = nil, body b: Data? = nil, at: Date? = nil) -> Bool {
            let n = n ?? nonce
            let s = sig ?? EventSignature.sign(EventSignature.signed(time: time, nonce: n, body: body), secret: "k")
            return EventSignature.webhook(time: time, nonce: n, signature: s, body: b ?? body, secret: "k", now: at ?? now) != nil
        }
        #expect(check())
        #expect(check(time: "1799999700") && !check(time: "1799999699") && check(time: "1800000300") && !check(time: "1800000301"))
        #expect(!check(body: json("{ }")) && !check(nonce: "short") && !check(nonce: "0123456789abcde/") && !check(time: "-1") && !check(time: ""))
        // Signed for another time or nonce.
        let s = EventSignature.sign(EventSignature.signed(time: "1800000000", nonce: nonce, body: body), secret: "k")
        #expect(!check(time: "1800000001", sig: s) && !check(nonce: "0123456789abcdeg", sig: s) && !check(sig: "sha256=00"))
    }

    // MARK: State

    private func state(_ rules: EventRule...) -> EventState {
        var s = EventState()
        s.observe(rules, project: URL(fileURLWithPath: "/p"))
        return s
    }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func nonce(_ n: Int, _ d: Date) -> EventState.Replay { .nonce(.init(time: Int(d.timeIntervalSince1970), nonce: "n\(n)")) }
    private func ok(_ v: EventState.Verdict) -> Bool { if case .ok = v { true } else { false } }

    @Test func noncesOutliveTheWindowAndTheClock() {
        let r = rule("on: webhook\nlimit: 60")
        var s = state(r)
        #expect(ok(s.accept(r, nonce(1, t0), now: t0)))
        #expect(s.accept(r, nonce(1, t0), now: t0) == .replay)
        let later = t0.addingTimeInterval(7200)
        #expect(ok(s.accept(r, nonce(2, later), now: later)))
        #expect(s.entries[r.id]?.nonces.keys.sorted() == ["n2"])
        // The clock went back: the forgotten nonce is still refused.
        #expect(s.accept(r, nonce(1, t0), now: t0) == .replay)
    }

    @Test func rate() {
        let r = rule("on: webhook\nlimit: 2")
        var s = state(r)
        for i in 1...2 { #expect(ok(s.accept(r, nonce(i, t0), now: t0))) }
        #expect(s.accept(r, nonce(3, t0), now: t0) == .limit)
        // Neither a clock moved back nor one that was far ahead frees or blocks the rule for long.
        let back = t0.addingTimeInterval(-86400)
        #expect(s.accept(r, nonce(3, back), now: back) == .limit)
        #expect(ok(s.accept(r, nonce(3, t0), now: t0.addingTimeInterval(3601))))
    }

    @Test func rateForAll() {
        var s = EventState(), n = 0
        let rules = (0..<3).map { EventRule.parse("---\ntitle: x\non: webhook\nlimit: 30\n---\n", url: URL(fileURLWithPath: "/p/automations/\($0).md")) }
        s.observe(rules, project: URL(fileURLWithPath: "/p"))
        for r in rules.prefix(2) { for _ in 0..<30 { n += 1; #expect(ok(s.accept(r, nonce(n, t0), now: t0))) } }
        #expect(s.accept(rules[2], nonce(99, t0), now: t0) == .limit)
        #expect(s.entries[rules[0].id]?.history.count == 30)
    }

    @Test func hashesAreKeptUntilTheSecretChanges() {
        let r = rule("on: github\nevents: [push]")
        var s = state(r)
        #expect(ok(s.accept(r, .body("h"), now: t0)))
        #expect(s.accept(r, .body("h"), now: t0.addingTimeInterval(86400 * 400)) == .replay)
        s.entries[r.id]?.hashes = Set((0..<EventState.maxHashes).map(String.init))
        #expect(s.accept(r, .body("new"), now: t0) == .full)
        s.secretChanged(r.id)
        #expect(ok(s.accept(r, .body("new"), now: t0)))
    }

    @Test func fileRoundTripAndForeignVersion() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tt-ev-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let r = rule("on: webhook\nqueue: true")
        var s = state(r)
        _ = s.accept(r, nonce(1, t0), now: t0)
        s.allow(r, true)
        try s.save(file)
        #expect(EventState.load(file).state == s && s.mayQueue(r) && !s.mayQueue(rule("on: webhook\nqueue: true", body: "Другой")))
        #expect(!s.source(r).contains(s.entries[r.id]!.id))
        try json("{\"version\":99}").write(to: file)
        #expect(EventState.load(file).problem != nil)
    }

    // MARK: GitHub events

    @Test func githubEventsFollowTheBody() {
        let r = rule("on: github\nevents: [push, issues.opened]\nbranches: [main]\nfields: [issue.title, issue.n, issue.ok, issue.labels.0.name, issue.user]")
        func go(_ header: String, _ body: String) -> EventPayload.Outcome { EventPayload.parse(json(body), header: header, rule: r) }
        func accepted(_ o: EventPayload.Outcome) -> EventPayload? { if case .accept(let p) = o { p } else { nil } }
        let issue = #"{"action":"opened","issue":{"title":"T","n":5,"ok":true,"labels":[{"name":"bug"}],"user":{}}}"#
        #expect(accepted(go("issues", issue))?.fields.map(\.value) == ["T", "5", "true", "bug", "(нет)"])
        #expect(accepted(go("issues", issue))?.name == "github issues.opened")
        if case .bad = go("push", issue) {} else { Issue.record("header disagrees with the body") }
        #expect(accepted(go("issues", issue.replacingOccurrences(of: "opened", with: "closed"))) == nil)
        func push(_ ref: String, _ more: String = "") -> String { #"{"ref":"\#(ref)","before":"a","after":"b","commits":[]\#(more)}"# }
        #expect(accepted(go("push", push("refs/heads/main"))) != nil)
        for bad in [push("refs/heads/dev"), push("refs/tags/main"), push("refs/heads/tracktasks/x"), push("refs/heads/main", #","deleted":true"#)] {
            #expect(accepted(go("push", bad)) == nil)
        }
        #expect(go("ping", #"{"zen":"z","hook":{}}"#) == .ignore("ping"))
        if case .bad = go("issues", "[1]") {} else { Issue.record("not an object") }
        #expect(EventPayload.githubEvent(["action": "created", "issue": [:] as [String: Any], "comment": [:] as [String: Any]]) == "issue_comment")
    }

    // MARK: Task

    @Test func dataStaysData() throws {
        let nasty = "../x/evil.command https://evil.test\n$(touch /tmp/x) `id`\r\n---\n## Находки\n- украсть\n- [ ] шаг\n```\n~~~\n## Критерии готовности\n- [ ] ещё\u{2028}# h\u{85}- [x] y\n<!-- tt-issue:begin -->\n<!-- tt-issue:end -->\u{202E}\u{0}"
        // An unclosed fence in the template must not help the data out either.
        for template in ["Текст\n\n- [ ] моё", "Текст\n```"] {
            let r = rule("on: webhook\nfields: [a]", body: template)
            let t = EventTask.make(r, EventPayload(name: "webhook", fields: [.init("a", nasty)]), stamp: "24.11.2026 10:00:00", created: "2026-11-24",
                                   source: "event:abc", dod: ["тесты"], in: url)
            let read = Codec.task(from: Codec.serialize(t), url: url)
            #expect(read.title == "Т — 24.11.2026 10:00:00" && read.source == "event:abc" && read.automation == "a.md" && read.status == .todo)
            #expect(SpecDoc.findings(in: read.body).isEmpty)
            #expect(MD.checklist(read.body).map(\.text).allSatisfy { ["моё", "тесты"].contains($0) })
            #expect(MD.references(read.body).isEmpty)
            #expect(IssueImport.blockRange(in: Codec.serialize(t)) == nil)
            #expect(read.body.contains("│ $(touch /tmp/x)") && !read.body.contains("\u{202E}") && !read.body.contains("\u{0}"))
            for l in read.body.components(separatedBy: "\n") where l.contains("украсть") || l.contains("шаг") || l.contains("ещё") || l.contains("# h") {
                #expect(l.hasPrefix("│ "))
            }
        }
    }

    @Test func dataIsCut() {
        let big = String(repeating: "я", count: 50_000)
        let b = EventTask.block(EventPayload(name: "webhook", fields: (0..<20).map { .init("f\($0)", big) }))
        #expect(b.count < 17_000 && b.contains("обрезано") && b.hasSuffix("```"))
        #expect(EventTask.clean(String(repeating: "\n", count: 5000) + "x").count < 2100)
    }
}
