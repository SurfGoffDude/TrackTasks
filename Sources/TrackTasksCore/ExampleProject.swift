import Foundation

/// The sample made by a button on the first run. Never touches what is already there.
public enum ExampleProject {
    public static let category = "examples", folder = "tracktasks-example"

    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func url(in root: URL) -> URL {
        root.appendingPathComponent(category, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
    }

    /// Blocks: not on the main thread.
    public static func create(in root: URL, today: String = Codec.today(), now: Date = Date()) throws -> (project: URL, task: URL) {
        let dir = url(in: root), fm = FileManager.default
        do { try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw Failure(message: "Не создана папка \(dir.deletingLastPathComponent().path): \(error.localizedDescription)") }
        // Fails on anything that is there, also a file or a link.
        guard mkdir(dir.path, 0o755) == 0 else {
            let why = errno
            throw Failure(message: why == EEXIST ? "Уже есть: \(dir.path). Ничего не изменено" : "Не создана папка \(dir.path): \(String(cString: strerror(why)))")
        }
        do {
            try about(today).write(to: dir.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
            try SpecDoc.template(name: name, idea: idea).write(to: SpecDoc.url(in: dir), atomically: true, encoding: .utf8)
            let tasks = dir.appendingPathComponent("tasks", isDirectory: true)
            let item = TaskItem(url: tasks, title: "Написать приветствие", status: .todo, priority: .medium, created: today,
                                completed: "", body: body, size: "s")
            return (dir, try TaskFile.create(item, in: tasks, now: now).url)
        } catch {
            throw Failure(message: "Пример создан не полностью: \(dir.path) — \(error.localizedDescription)")
        }
    }

    static let name = "Пример TrackTasks"
    private static let idea = "Учебный проект: посмотреть, как выглядят описание, спецификация и задачи. Его можно удалить."

    private static func about(_ today: String) -> String {
        """
        ---
        name: \(Frontmatter.quote(name))
        category: \(category)
        status: active
        stack: [Markdown]
        updated: \(today)
        ---

        # \(name)

        \(idea)

        """
    }

    private static let body = """
    Создать файл hello.md с коротким приветствием. Задачу можно сделать самому или отдать агенту.

    - [ ] Создать hello.md в корне проекта
    - [ ] Написать в нём одно-два предложения

    ## Критерии готовности
    - [ ] hello.md существует и не пуст
    """
}
