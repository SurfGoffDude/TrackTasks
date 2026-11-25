import Testing
@testable import TrackTasksCore

@Suite("DirtyFiles")
struct DirtyFilesTests {
    @Test func trackerFilesDontCount() {
        let paths = ["tasks/20261116-a.md", "about.md", "spectrack.md", "SPECTRACK.md", ".claude/settings.json", "tasks"]
        #expect(DirtyFiles.significant(paths).isEmpty)
    }

    @Test func codeFilesCount() {
        let paths = ["Sources/App.swift", "tasks/x.md", "Package.swift", "docs/about.md", "tasksfoo.txt"]
        #expect(DirtyFiles.significant(paths) == ["Package.swift", "Sources/App.swift", "docs/about.md", "tasksfoo.txt"])
    }

    @Test func parsesPorcelainZ() {
        let out = " M Sources/A.swift\0?? Tests/B Тест.swift\0R  new.swift\0old.swift\0M  about.md\0"
        let paths = DirtyFiles.parsePorcelainZ(out)
        #expect(paths == ["Sources/A.swift", "Tests/B Тест.swift", "new.swift", "old.swift", "about.md"])
        #expect(DirtyFiles.significant(paths) == ["Sources/A.swift", "Tests/B Тест.swift", "new.swift", "old.swift"])
    }

    @Test func onlyScheduleFilesOfAutomations() {
        #expect(DirtyFiles.significant(["automations/a.md", "automations/run.py", "automations/x/a.md"]) == ["automations/run.py", "automations/x/a.md"])
    }

    @Test func emptyStatus() {
        #expect(DirtyFiles.parsePorcelainZ("").isEmpty)
    }

    @Test func overlapAndSummary() {
        let o = DirtyFiles.overlap(branch: ["a.swift", "b.swift", "c.swift"], dirty: ["c.swift", "a.swift", "z.swift"])
        #expect(o == ["a.swift", "c.swift"])
        #expect(DirtyFiles.summary(["a", "b", "c", "d", "e"]) == "a, b, c +2")
        #expect(DirtyFiles.summary(["a"]) == "a")
    }
}
