import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct CodexRulesTests {
    @Test(arguments: [
        "", "# decision=\"allow\"\n",
        #"prefix_rule(pattern=["git", "push"], decision="prompt")"#,
        "prefix_rule(\n  pattern = ['rm', ['-r', '-rf']], # prefix_rule(\n  decision = 'forbidden',\n  justification = 'a (b) decision=\"allow\"',\n)\nprefix_rule(decision=\"prompt\", pattern=[\"x\"])\n",
    ]) func restricting(_ text: String) { #expect(CodexRules.onlyRestricts(text)) }

    @Test(arguments: [
        #"prefix_rule(pattern=["ls"], decision="allow")"#,
        #"prefix_rule(pattern=["ls"])"#,
        #"prefix_rule(["ls"], "allow")"#,
        #"prefix_rule(["ls"], decision="prompt")"#,
        #"prefix_rule(pattern=["ls"], justification="decision='prompt'")"#,
        #"prefix_rule(pattern=["prompt"])"#,
        #"prefix_rule(pattern=["ls"], decision="prompt" and "allow")"#,
        #"prefix_rule(pattern=["ls"], decision="al" + "low")"#,
        #"prefix_rule(pattern=["ls"], decision="prompt"); prefix_rule(pattern=["x"])"#,
        "r = prefix_rule\nr(pattern=['ls'])",
        "def f():\n  prefix_rule(pattern=['ls'])\nf()",
        #"prefix_rule(pattern=["""x"""], decision="prompt")"#,
        #"prefix_rule(pattern=["\""], decision="prompt")"#,
        #"network_rule(host="x", protocol="https", decision="allow")"#,
        #"prefix_rule(pattern=["ls], decision="prompt")"#,
        "prefix_rule(pattern=S, decision=R)",
    ]) func mayAllow(_ text: String) { #expect(!CodexRules.onlyRestricts(text)) }

    @Test func files() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("codex-rules-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let missing = dir.appendingPathComponent("none")
        #expect(CodexRules.blocking([missing, dir]) == nil)
        try "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "prefix_rule(pattern=['x'], decision='prompt')".write(to: dir.appendingPathComponent("a.rules"), atomically: true, encoding: .utf8)
        #expect(CodexRules.blocking([dir]) == nil)
        // Unreadable: not UTF-8, a dangling link, a file instead of the folder.
        let bad = dir.appendingPathComponent("b.rules")
        try Data([0xFF, 0xFE, 0x00]).write(to: bad)
        #expect(CodexRules.blocking([missing, dir]) == bad.path)
        try fm.removeItem(at: bad)
        try fm.createSymbolicLink(at: bad, withDestinationURL: missing)
        #expect(CodexRules.blocking([dir]) == bad.path)
        #expect(CodexRules.blocking([dir.appendingPathComponent("a.txt")]) != nil)
    }

    @Test func places() {
        let d = CodexRules.dirs(codexHome: URL(fileURLWithPath: "/h"), folders: [URL(fileURLWithPath: "/nope/wt"), URL(fileURLWithPath: "/nope/main/tasks")]).map(\.path)
        for p in ["/h/rules", "/etc/codex/rules", "/nope/wt/.codex/rules", "/nope/main/.codex/rules", "/.codex/rules"] { #expect(d.contains(p), "\(p)") }
        #expect(Set(d).count == d.count)
    }
}
