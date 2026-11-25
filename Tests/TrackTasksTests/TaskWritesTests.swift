import Foundation
import Testing
@testable import TrackTasksCore
@testable import TrackTasks

/// The app's writes of task files next to `tt`.
@MainActor @Suite(.serialized) struct TaskWritesTests {
    nonisolated static let name = "20261101-100000-alpha.md"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-\(UUID().uuidString)", isDirectory: true)
    var project: URL { root.appendingPathComponent("cat/proj", isDirectory: true) }
    var tasks: URL { project.appendingPathComponent("tasks", isDirectory: true) }
    var file: URL { tasks.appendingPathComponent(Self.name) }

    init() throws {
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        try Data("""
            ---
            title: "Альфа"
            status: todo        # todo | doing | done
            priority: medium
            created: 2026-11-01
            completed:
            tags: [x]
            ---

            Описание.

            - [ ] раз
            - [ ] два

            ## Заметки
            - 01.11 10:00 — начало

            """.utf8).write(to: file)
    }

    private func cleanUp() {
        chmod(tasks.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }
    nonisolated private func tt(_ project: URL, _ root: URL, _ args: String...) -> Int32 {
        CLI(cwd: project, root: root, out: { _ in }, err: { _ in }).run(args)
    }
    private func tt(_ args: String...) -> Int32 { CLI(cwd: project, root: root, out: { _ in }, err: { _ in }).run(args) }
    private var text: String { get throws { try String(contentsOf: file, encoding: .utf8) } }
    private func save(_ t: TaskItem, _ base: TaskItem) async -> Result<TaskItem, Error> {
        await TaskWrites.run { try TaskFile.save(t, base: base) }
    }

    @Test func editOfTtBetweenReadAndWriteStays() async throws {
        defer { cleanUp() }
        let base = try #require(Codec.task(at: file))
        #expect(tt("edit", Self.name, "--status", "doing", "--check", "1", "--note", "от tt") == 0)
        // A field nobody knows, added by hand.
        try Data(try text.replacingOccurrences(of: "tags: [x]", with: "tags: [x, y] # моё")
            .utf8).write(to: file)
        var mine = base
        mine.title = "Бета"
        mine.body = MD.appendNote(MD.toggleTask(mine.body, 1), "от приложения")
        mine.depends = ["20261101-100009-other.md"]
        let saved = try await save(mine, base).get()
        let t = try #require(Codec.task(at: file))
        #expect(saved.title == "Бета" && t.title == "Бета" && t.status == .doing && t.depends == mine.depends)
        #expect(t.body.contains("- [x] раз\n- [x] два"))
        #expect(MD.notes(t.body).count == 3 && t.body.contains("от tt") && t.body.contains("от приложения"))
        #expect(try text.contains("tags: [x, y] # моё") && text.contains("# todo | doing | done"))
    }

    @Test func clashWritesNothingAndCanBeForced() async throws {
        defer { cleanUp() }
        let base = try #require(Codec.task(at: file))
        #expect(tt("edit", Self.name, "--title", "Из tt", "--priority", "high") == 0)
        let before = try text
        var mine = base
        mine.title = "Моё"
        guard case .failure(let e) = await save(mine, base), let c = e as? TaskMerge.Conflict else {
            Issue.record("нет конфликта"); return
        }
        #expect(c.fields == ["название"])
        #expect(try text == before)
        _ = try await save(c.merged, c.current).get()
        let t = try #require(Codec.task(at: file))
        #expect(t.title == "Моё" && t.priority == .high)
    }

    @Test func parallelWritesLoseNothing() async throws {
        defer { cleanUp() }
        let n = 30, file = file, project = project, root = root
        let outside = Task.detached { () -> Bool in
            for i in 0..<n {
                // `tt` refuses when the file changed since it read it; nothing was written, so it is run again.
                var code: Int32 = 1, left = 500
                while code != 0, left > 0 {
                    code = self.tt(project, root, "edit", Self.name, "--note", "tt-\(i)-")
                    left -= 1
                }
                guard code == 0 else { return false }
            }
            return true
        }
        for i in 0..<n {
            if i.isMultiple(of: 2) {
                _ = try await TaskWrites.run { try TaskFile.change(file) { $0.body = MD.appendNote($0.body, "app-\(i)-") } }.get()
            } else {
                let base = try #require(Codec.task(at: file))
                await Task.yield()
                var mine = base
                mine.body = MD.appendNote(mine.body, "app-\(i)-")
                _ = try await save(mine, base).get()
            }
        }
        #expect(await outside.value)
        let t = try text
        for i in 0..<n {
            #expect(t.components(separatedBy: "tt-\(i)-").count == 2)
            #expect(t.components(separatedBy: "app-\(i)-").count == 2)
        }
    }

    @Test func failureIsReportedAndFileIsWhole() async throws {
        defer { cleanUp() }
        let base = try #require(Codec.task(at: file)), before = try Data(contentsOf: file)
        var mine = base
        mine.title = "Бета"
        let sent = mine
        chmod(tasks.path, 0o555)
        // The same path the windows use: the error reaches the person.
        let r = await Store.SaveResult(TaskWrites.run { try TaskFile.save(sent, base: base) })
        guard case .failed(let message) = r else { Issue.record("ошибки нет"); return }
        #expect(!message.isEmpty)
        chmod(tasks.path, 0o755)
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tasks.path) == [Self.name])
        // A deleted task is not made anew.
        try FileManager.default.removeItem(at: file)
        guard case .failed = await Store.SaveResult(TaskWrites.run { try TaskFile.save(sent, base: base) }) else {
            Issue.record("ошибки нет"); return
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func lockIsNotWaitedForOnMainThread() async throws {
        defer { cleanUp() }
        let base = try #require(Codec.task(at: file)), before = try text
        var mine = base
        mine.title = "Бета"
        let fd = open(tasks.path, O_RDONLY)
        try #require(fd >= 0 && flock(fd, LOCK_EX) == 0)
        var done = false
        let sent = mine
        let write = Task { @MainActor in
            let r = await save(sent, base)
            done = true
            return r
        }
        // The main actor goes on while the write waits.
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!done)
        #expect(try text == before)
        close(fd)
        #expect(try await write.value.get().title == "Бета")
        #expect(try await TaskWrites.run { Thread.isMainThread }.get() == false)
    }
}
