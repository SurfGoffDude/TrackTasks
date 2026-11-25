import Testing
import Foundation
@testable import TrackTasksCore

@Suite struct DefinitionOfDoneTests {
    let about = """
    ---
    name: X
    ---

    # X

    Описание.

    ## Definition of Done
    - [ ] Тесты проходят
    - Обновлён README
    - [ ] тесты проходят

    ## Другое
    текст
    """

    @Test func parsesItemsOnce() {
        #expect(DefinitionOfDone.items(inAbout: about) == ["Тесты проходят", "Обновлён README"])
        #expect(DefinitionOfDone.items(inAbout: "# X\n\n## Критерии готовности\n- [ ] a") == [])
    }

    @Test func findsSectionAfterCriteriaHeadingAndNumbered() {
        let t = "---\nname: X\n---\n\n## Критерии готовности\n- [ ] чужое\n\n## Definition of Done\n1. Первое\n2) Второе\n\n## Methodology dod\n- [ ] нет\n"
        #expect(DefinitionOfDone.items(inAbout: t) == ["Первое", "Второе"])
        let out = DefinitionOfDone.setting(["Новое"], inAbout: t)
        #expect(out.components(separatedBy: "## Definition of Done").count == 2)
        #expect(DefinitionOfDone.items(inAbout: out) == ["Новое"])
        #expect(out.contains("- [ ] чужое") && out.contains("## Methodology dod"))
    }

    @Test func ttNewAppliesDoD() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try about.write(to: dir.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
        #expect(DefinitionOfDone.items(inProject: dir) == ["Тесты проходят", "Обновлён README"])
        let body = DefinitionOfDone.apply(DefinitionOfDone.items(inProject: dir), to: "Описание\n\n## Критерии готовности\n- [ ] Свой")
        #expect(MD.checklist(body, in: .criteria).map(\.text) == ["Свой", "Тесты проходят", "Обновлён README"])
    }

    @Test func appliesWithoutDuplicates() {
        let body = "Описание\n\n- [ ] шаг\n\n## Критерии готовности\n- [ ] Тесты проходят\n"
        let once = DefinitionOfDone.apply(["Тесты проходят", "Обновлён README"], to: body)
        #expect(MD.checklist(once, in: .criteria).map(\.text) == ["Тесты проходят", "Обновлён README"])
        #expect(DefinitionOfDone.apply(["Тесты проходят", "Обновлён README"], to: once) == once)
        let blank = DefinitionOfDone.apply(["A"], to: "")
        #expect(MD.checklist(blank, in: .criteria).map(\.text) == ["A"])
        #expect(DefinitionOfDone.apply([], to: body) == body)
    }

    @Test func settingReplacesAndCreatesSection() {
        let out = DefinitionOfDone.setting(["Один", "Два"], inAbout: about)
        #expect(DefinitionOfDone.items(inAbout: out) == ["Один", "Два"])
        #expect(out.contains("## Другое"))
        let fresh = DefinitionOfDone.setting(["Один"], inAbout: "---\nname: X\n---\n\n# X\n")
        #expect(DefinitionOfDone.items(inAbout: fresh) == ["Один"])
        let cleared = DefinitionOfDone.setting([], inAbout: about)
        #expect(DefinitionOfDone.items(inAbout: cleared).isEmpty)
        #expect(cleared.contains("## Другое"))
    }
}
