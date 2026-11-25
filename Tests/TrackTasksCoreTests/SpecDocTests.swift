import Foundation
import Testing
@testable import TrackTasksCore

@Suite("SpecDoc")
struct SpecDocTests {
    @Test func findingsParsed() {
        let t = "Текст\n\n```\n## Находки\n- не это\n```\n\n## Находки\n- один\n  продолжение\n- два\n\n## Итог\n- три"
        #expect(SpecDoc.findings(in: t) == ["один продолжение", "два"])
        #expect(SpecDoc.findings(in: "## Итог\n- три").isEmpty)
    }

    @Test func removingKeepsOtherSections() {
        let t = "Текст\n\n## Находки\n- один\n\n## Итог\nготово"
        #expect(SpecDoc.removingFindings(from: t) == "Текст\n\n## Итог\nготово")
        #expect(SpecDoc.removingFindings(from: "Текст") == "Текст")
    }

    @Test func addsInsideExistingSection() {
        let t = "# S\n\n## Находки\n\n- старая\n\n## Хвост\nтекст\n"
        #expect(SpecDoc.adding(["новая"], task: "a.md", date: "23.11.2026", to: t)
            == "# S\n\n## Находки\n\n- старая\n- 23.11.2026 — новая (tasks/a.md)\n\n## Хвост\nтекст\n")
    }

    @Test func createsSectionAndSkipsDuplicates() {
        let once = SpecDoc.adding(["x", "x"], task: "a.md", date: "01.01.2026", to: "# S\n")
        #expect(once == "# S\n\n## Находки\n\n- 01.01.2026 — x (tasks/a.md)\n")
        #expect(SpecDoc.adding(["x"], task: "a.md", date: "02.01.2026", to: once) == once)
        #expect(SpecDoc.adding([], task: "a.md", date: "", to: "abc") == "abc")
    }

    @Test func templateAcceptsFindings() {
        let t = SpecDoc.adding(["x"], task: "a.md", date: "01.01.2026", to: SpecDoc.template(name: "P"))
        #expect(SpecDoc.findings(in: t) == ["01.01.2026 — x (tasks/a.md)"])
    }

    @Test func projectReadsSpecKeepingLetterCase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!Codec.project(at: dir, category: "c").hasSpec)
        try "# Hi".write(to: dir.appendingPathComponent("SPECTRACK.md"), atomically: true, encoding: .utf8)
        let p = Codec.project(at: dir, category: "c")
        #expect(p.hasSpec && p.spec == "# Hi")
        #expect(p.specURL.lastPathComponent == "SPECTRACK.md")
    }
}
