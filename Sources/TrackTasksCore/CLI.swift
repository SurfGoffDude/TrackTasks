import Foundation

/// `tt`: tasks from the terminal, straight on the files — the app does not have to run.
/// The executable only supplies the environment; everything else is here, under tests.
public struct CLI {
    public static let schema = 1
    /// The only place with the version: tools/stamp-version.sh puts it into the app's Info.plist.
    public static let version = "1.1.1"

    public var cwd: URL
    public var root: URL
    public var extras: [String]
    public var isTTY: Bool
    /// stdin is a terminal too: only then `tt board` is interactive.
    public var stdinTTY = false
    public var stdin: () -> String?
    public var out: (String) -> Void
    public var err: (String) -> Void
    /// Only projects of `ProjectScan.entries` and nothing outside their folders, symlinks included (MCP).
    var confined = false
    /// Next bytes of stdin, nil or empty at the end (`tt mcp`).
    var input: () -> Data? = { nil }
    /// Path of this `tt`, for `tt mcp --config`.
    var executable = "tt"
    /// Sends a request to the running app.
    var transport: (QueueRequest) throws -> QueueResponse

    public init(cwd: URL, root: URL, extras: [String] = [], isTTY: Bool = false, stdinTTY: Bool = false, stdin: @escaping () -> String? = { nil },
                transport: @escaping (QueueRequest) throws -> QueueResponse = { _ in
                    throw QueueFailure(.unavailable, "нет связи с TrackTasks")
                },
                out: @escaping (String) -> Void, err: @escaping (String) -> Void,
                input: @escaping () -> Data? = { nil }, executable: String = "tt") {
        self.cwd = cwd
        self.root = root
        self.extras = extras
        self.isTTY = isTTY
        self.stdinTTY = stdinTTY
        self.stdin = stdin
        self.out = out
        self.err = err
        self.transport = transport
        self.input = input
        self.executable = executable
    }

    /// Result of a command: JSON fields (besides `schema` / `command`) and the text form.
    struct Output {
        var json: [String: Any]
        var text: String
        var warnings: [String] = []
    }

    struct Context {
        var url: URL
        var files: [TaskFile]
        var unreadable: [String]
        /// Archive and drafts: not listed, but `depends:` may point there.
        var parked: [TaskItem]

        var name: String { url.lastPathComponent }
        var tasksURL: URL { url.appendingPathComponent("tasks", isDirectory: true) }

        /// A project that must not be read: only shows up as unreadable.
        init(refused url: URL) {
            self.url = url
            files = []
            unreadable = [""]
            parked = []
        }

        init(_ url: URL, accept: (URL) -> Bool = { _ in true }) throws {
            self.url = url
            let dir = url.appendingPathComponent("tasks", isDirectory: true)
            (files, unreadable) = try TaskFile.all(in: dir, accept: accept)
            parked = (Codec.rawTasks(in: TaskFolder.archive.url(in: dir)) + Codec.rawTasks(in: TaskFolder.drafts.url(in: dir)))
                .filter { accept($0.url) }
        }

        func openDepends(_ t: TaskItem) -> [String] {
            let done = DependencyPlan.satisfied(files.map(\.item), parked)
            return t.depends.filter { !done.contains($0) }
        }
    }

    private struct Spec {
        var options: Set<String> = []
        var flags: Set<String> = []
        var positional: ClosedRange<Int>
    }

    private static let specs: [String: Spec] = {
        let filters: Set<String> = ["status", "priority", "size"]
        let edit: Set<String> = ["title", "status", "priority", "size", "agent", "depends", "add-depend", "rm-depend", "files", "repos", "verify", "body", "item",
                                 "criterion", "check", "uncheck", "note", "if-rev"]
        return [
            "list": Spec(options: filters, flags: ["all", "ready", "watch"], positional: 0...0),
            "board": Spec(options: ["priority", "size"], flags: ["all", "watch"], positional: 0...0),
            "search": Spec(options: filters, flags: ["all", "watch"], positional: 1...Int.max),
            "show": Spec(flags: ["watch"], positional: 1...1),
            "add": Spec(options: ["priority", "size", "agent", "depends", "files", "repos", "verify", "body", "item", "criterion"], flags: ["force"], positional: 1...1),
            "edit": Spec(options: edit, flags: ["force"], positional: 1...1),
            "done": Spec(options: ["note", "if-rev"], flags: ["force"], positional: 1...1),
            "queue": Spec(options: ["tail"], flags: ["all", "with-deps"], positional: 1...Int.max),
            "mcp": Spec(flags: ["config"], positional: 0...0),
            "instructions": Spec(positional: 0...0),
            "help": Spec(positional: 0...1),
            "version": Spec(positional: 0...0),
        ]
    }()

    // MARK: Run

    public func run(_ argv: [String]) -> Int32 {
        // Known before parsing: a parse error must be JSON too.
        let json = argv.prefix { $0 != "--" }.contains("--json")
        var command = ""
        do {
            var rest = argv
            var lead: [String] = []
            while let f = rest.first, f == "--json" { lead.append(rest.removeFirst()) }
            switch rest.first {
            case nil, "-h"?, "--help"?: command = "help"
            case "--version"?: command = "version"
            case let c?: command = c
            }
            guard let spec = Self.specs[command] else {
                let bad = command
                command = ""
                throw CLIError.usage("неизвестная команда «\(bad)», см. tt help")
            }
            let args = try CLIArgs(lead + rest.dropFirst(), options: spec.options.union(["project"]),
                                   flags: spec.flags.union(["json", "help"]))
            if args.has("help") { command = "help" }
            if command != "help", !spec.positional.contains(args.positional.count) {
                throw CLIError.usage("tt \(command): неверное число аргументов, см. tt help")
            }
            if command != "queue", args.has("all"), args.values["project"] != nil { throw CLIError.usage("--all и --project вместе не имеют смысла") }
            if command == "mcp" {
                guard !json, args.values["project"] == nil else { throw CLIError.usage("tt mcp не принимает --json и --project") }
                if args.has("config") { out(MCPConfig.text(executable)) } else { MCPServer(self).serve() }
                return 0
            }
            if command == "board", !json, !args.has("watch"), isTTY, stdinTTY, let code = try interactiveBoard(args) { return code }
            if args.has("watch") { return try watch(command, args, json: json) }
            emit(command, try execute(command, args), json: json)
            return 0
        } catch {
            return fail(command, error, json: json)
        }
    }

    private func fail(_ command: String, _ error: Error, json: Bool, pretty: Bool = true) -> Int32 {
        let e = CLIError(error)
        if json {
            out(Self.encode(["schema": Self.schema, "command": command,
                             "error": ["code": e.code.name, "exit": Int(e.code.rawValue), "message": e.message]], pretty: pretty))
        } else {
            err("tt: \(e.message)\n")
        }
        return e.code.rawValue
    }

    private func emit(_ command: String, _ o: Output, json: Bool) {
        for w in o.warnings { err("tt: \(w)\n") }
        out(json ? Self.document(command, o, pretty: true) : o.text)
    }

    private static func document(_ command: String, _ o: Output, pretty: Bool) -> String {
        encode(o.json.merging(["schema": schema, "command": command]) { $1 }, pretty: pretty)
    }

    private static func encode(_ o: [String: Any], pretty: Bool) -> String {
        let opts: JSONSerialization.WritingOptions = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
                                                            : [.sortedKeys, .withoutEscapingSlashes]
        // Only strings, numbers, arrays, dictionaries and NSNull get here.
        let data = try! JSONSerialization.data(withJSONObject: o, options: opts)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    func execute(_ command: String, _ args: CLIArgs) throws -> Output {
        switch command {
        case "list": try list(args)
        case "board": try board(args)
        case "search": try search(args)
        case "show": try show(args)
        case "add": try add(args)
        case "edit", "done": try change(args, done: command == "done")
        case "queue": try queue(args)
        case "instructions": Output(json: ["instructions": Self.instructions], text: Self.instructions)
        case "version": Output(json: ["version": Self.version], text: "tt \(Self.version) (TrackTasks)\n")
        default: Output(json: ["help": Self.help], text: Self.help)
        }
    }

    /// Prints the result again whenever it changes. With `--json` — one document per line.
    private func watch(_ command: String, _ args: CLIArgs, json: Bool) throws -> Int32 {
        // Wrong arguments or a missing project end the command; later errors are shown and watching goes on.
        _ = try execute(command, args)
        let paths: [String]
        if args.has("all") { paths = [root.path] + extras }
        else if command == "show" { paths = [try task(args.positional[0], args).0.url.path] }
        else { paths = [try projectURL(args).path] }
        let tick = DispatchSemaphore(value: 0)
        let watcher = FileWatcher(paths: paths) { events in
            if events.contains(where: { Self.matters($0) }) { tick.signal() }
        }
        var last = ""
        func show(_ s: String) {
            guard s != last else { return }
            if isTTY, !json { out("\u{1B}[H\u{1B}[2J") } else if !json, !last.isEmpty { out("\n") }
            last = s
            out(s)
        }
        while true {
            do {
                let o = try execute(command, args)
                show(json ? Self.document(command, o, pretty: false) : o.text)
            } catch {
                let e = CLIError(error)
                if json {
                    var text = ""
                    var copy = self
                    copy.out = { text += $0 }
                    _ = copy.fail(command, e, json: true, pretty: false)
                    show(text)
                } else {
                    err("tt: \(e.message)\n")
                }
            }
            withExtendedLifetime(watcher) { tick.wait() }
            while tick.wait(timeout: .now()) == .success {}
        }
    }

    static func matters(_ e: FileWatcher.Event) -> Bool {
        if e.mustRescan { return true }
        let u = URL(fileURLWithPath: e.path)
        if u.lastPathComponent == "tasks" { return true }
        let dir = u.deletingLastPathComponent()
        // tasks/archive and tasks/drafts change which dependencies are done.
        if dir.lastPathComponent == "tasks", TaskFolder(rawValue: u.lastPathComponent) != nil { return true }
        guard u.pathExtension.lowercased() == "md" else { return false }
        return dir.lastPathComponent == "tasks" || TaskFolder(of: u) != .active
    }

    // MARK: Projects and references

    private func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    private func isProject(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("about.md").path) { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("tasks").path)) ?? []
        return names.contains(where: TaskLint.isValidFileName)
    }

    private func path(_ s: String) -> URL {
        let p = (s as NSString).expandingTildeInPath
        return (p.hasPrefix("/") ? URL(fileURLWithPath: p) : cwd.appendingPathComponent(p)).standardizedFileURL
    }

    func projectURL(_ args: CLIArgs) throws -> URL {
        if let name = try args.one("project") {
            guard !name.isEmpty else { throw CLIError.usage("--project: пустое значение") }
            if name.contains("/") || name.hasPrefix(".") || name == "~" {
                let url = path(name)
                guard isDir(url) else { throw confined ? Self.outside(name) : CLIError.notFound("нет папки \(url.path)") }
                return try checkout(url, name)
            }
            let hits = ProjectScan.entries(root: root, extras: extras).map(\.url)
                .filter { $0.lastPathComponent.lowercased() == name.lowercased() }
            guard hits.count < 2 else {
                throw CLIError.notFound("несколько проектов «\(name)», укажи путь: " + hits.map(\.path).joined(separator: ", "))
            }
            guard let hit = hits.first else { throw CLIError.notFound("нет проекта «\(name)» в \(root.path)") }
            return try allowed(hit, name)
        }
        let here = try checkout(cwd, cwd.path, inside: true)
        let real = here.resolvingSymlinksInPath().path
        for e in extras {
            let p = URL(fileURLWithPath: e).resolvingSymlinksInPath().path
            if real == p || real.hasPrefix(p + "/") { return try allowed(URL(fileURLWithPath: p, isDirectory: true), p) }
        }
        // <root>/<category>/<project>: a nested folder that happens to be called tasks/ does not matter.
        let rootPath = root.resolvingSymlinksInPath().path
        if real.hasPrefix(rootPath + "/") {
            let parts = real.dropFirst(rootPath.count + 1).split(separator: "/")
            if parts.count >= 2 {
                return try allowed(URL(fileURLWithPath: rootPath + "/" + parts[0] + "/" + parts[1], isDirectory: true), cwd.path)
            }
        }
        var up = here
        while up.path != "/" {
            if isProject(up) { return try allowed(up, cwd.path) }
            up = up.deletingLastPathComponent()
        }
        throw CLIError.notFound("текущая папка не в проекте: нет about.md и tasks/, укажи --project")
    }

    private static func outside(_ what: String) -> CLIError { .invalid("«\(what)» вне проектов TrackTasks") }

    /// Main folder of `dir`; confined — only when it is a known project (`inside`: checked by the caller).
    private func checkout(_ dir: URL, _ what: String, inside: Bool = false) throws -> URL {
        guard confined else { return ProjectScan.mainCheckout(dir) }
        guard let main = ProjectScan.verifiedCheckout(dir) else { throw Self.outside(what) }
        return inside ? main : try allowed(main, what)
    }

    private func allowed(_ project: URL, _ what: String) throws -> URL {
        guard confined else { return project }
        guard knownProjects().contains(project.resolvingSymlinksInPath().path) else { throw Self.outside(what) }
        return project
    }

    /// Real paths of every known project.
    private func knownProjects() -> Set<String> {
        Set(ProjectScan.entries(root: root, extras: extras).map { $0.url.resolvingSymlinksInPath().path })
    }

    /// Confined: only jobs of known projects. The app may watch a wider folder than `root`.
    func visible(_ jobs: [QueueJob]) -> [QueueJob] {
        guard confined else { return jobs }
        let known = knownProjects()
        return jobs.filter { known.contains(URL(fileURLWithPath: $0.projectPath).resolvingSymlinksInPath().path) }
    }

    /// Every read of a project goes through here. Confined: no symlinks in its `tasks/`.
    /// A symlink swapped in after the check is not caught.
    func context(_ project: URL) throws -> Context {
        guard confined else { return try Context(project) }
        let tasks = project.appendingPathComponent("tasks", isDirectory: true)
        for u in [tasks, tasks.appendingPathComponent("archive"), tasks.appendingPathComponent("drafts")] where Self.isSymlink(u) {
            throw Self.outside(u.path)
        }
        // Its Definition of Done is copied into new tasks.
        let about = project.appendingPathComponent("about.md")
        if Self.isSymlink(about), !about.resolvingSymlinksInPath().path.hasPrefix(project.resolvingSymlinksInPath().path + "/") {
            throw Self.outside(about.path)
        }
        return try Context(project) { !Self.isSymlink($0) }
    }

    /// Also true for a link to nothing: creating folders would follow it.
    private static func isSymlink(_ u: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: u.path)) != nil
    }

    func contexts(_ args: CLIArgs) throws -> [Context] {
        guard args.has("all") else { return [try context(projectURL(args))] }
        return try ProjectScan.entries(root: root, extras: extras)
            // One folder with a symlink outside must not hide the other projects.
            .map { e in confined ? (try? context(e.url)) ?? Context(refused: e.url) : try context(e.url) }
            .filter { !$0.files.isEmpty || !$0.unreadable.isEmpty }
            .sorted { $0.url.path < $1.url.path }
    }

    /// File by path, name (with or without .md) or a unique part of the name.
    func task(_ ref: String, _ args: CLIArgs) throws -> (Context, TaskFile) {
        var name = ref
        let ctx: Context
        if ref.contains("/") {
            let url = path(ref)
            guard url.deletingLastPathComponent().lastPathComponent == "tasks" else {
                throw CLIError.notFound("\(ref): файл не в папке tasks/")
            }
            name = url.lastPathComponent
            ctx = try context(checkout(url.deletingLastPathComponent().deletingLastPathComponent(), ref))
        } else {
            ctx = try context(projectURL(args))
        }
        return (ctx, try find(name, in: ctx))
    }

    private func find(_ ref: String, in ctx: Context) throws -> TaskFile {
        let low = ref.lowercased()
        guard !low.isEmpty else { throw CLIError.usage("пустое имя задачи") }
        if let f = ctx.files.first(where: { [low, low + ".md"].contains($0.item.fileName.lowercased()) }) { return f }
        if ctx.unreadable.contains(where: { [low, low + ".md"].contains($0.lowercased()) }) {
            throw TaskFile.Failure.unreadable(ref)
        }
        let hits = ctx.files.filter { $0.item.fileName.lowercased().contains(low) }
        if hits.count > 1 {
            throw CLIError.notFound("«\(ref)» подходит к нескольким задачам: " + hits.map(\.item.fileName).joined(separator: ", "))
        }
        guard let hit = hits.first else { throw CLIError.notFound("нет задачи «\(ref)» в \(ctx.tasksURL.path)") }
        return hit
    }

    // MARK: JSON and text of a task

    func orNull(_ s: String) -> Any { s.isEmpty ? NSNull() : s }

    private func progress(_ items: [MD.CheckItem]) -> [String: Any] {
        ["done": items.filter(\.done).count, "total": items.count]
    }

    private func json(_ f: TaskFile, _ ctx: Context) -> [String: Any] {
        let t = f.item
        return [
            "file": t.fileName, "path": f.url.path, "rev": f.rev,
            "project": ["name": ctx.name, "path": ctx.url.path],
            "title": t.title, "status": t.status.rawValue, "priority": t.priority.rawValue,
            "size": orNull(t.size), "agent": orNull(t.agent), "created": orNull(t.created), "completed": orNull(t.completed),
            "parent": orNull(t.parent), "depends": t.depends, "openDepends": ctx.openDepends(t), "files": t.files, "repos": t.repos,
            "verify": orNull(t.verify),
            "checklist": progress(MD.checklist(t.body)), "criteria": progress(MD.checklist(t.body, in: .criteria)),
            "problems": t.problems.map(\.message),
        ]
    }

    /// Text output never passes control characters of a file to the terminal.
    func clean(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control }))
    }

    private func line(_ f: TaskFile, _ ctx: Context, project: Bool) -> String {
        let t = f.item
        let mark = switch t.status { case .todo: "[ ]"; case .doing: "[~]"; case .done: "[x]" }
        var tags = [t.priority.rawValue]
        if !t.size.isEmpty { tags.append(t.size) }
        let items = MD.checklist(t.body) + MD.checklist(t.body, in: .criteria)
        if !items.isEmpty { tags.append("\(items.filter(\.done).count)/\(items.count)") }
        if t.status != .done, !ctx.openDepends(t).isEmpty { tags.append("ждёт \(ctx.openDepends(t).count)") }
        if !t.problems.isEmpty { tags.append("проблем: \(t.problems.count)") }
        return clean("\(mark) \(project ? ctx.name + ": " : "")\(t.title) (\(tags.joined(separator: ", "))) \(t.fileName)") + "\n"
    }

    func unreadable(_ all: [Context]) -> [String] {
        all.flatMap { c in c.unreadable.map { c.tasksURL.appendingPathComponent($0).path } }
    }

    private func output(_ all: [Context], _ picked: [(Context, TaskFile)], text: String) -> Output {
        let bad = unreadable(all)
        return Output(json: ["tasks": picked.map { json($0.1, $0.0) }, "unreadable": bad], text: text,
                      warnings: bad.map { "не читается (или не UTF-8): \($0)" })
    }

    // MARK: Reading commands

    func matching(_ args: CLIArgs, _ all: [Context], defaultStatuses: [TaskStatus]) throws -> [(Context, TaskFile)] {
        var statuses = try args.choices("status", TaskStatus.self)
        if statuses.isEmpty { statuses = defaultStatuses }
        let priorities = try args.choices("priority", Priority.self)
        let sizes = try args.choices("size", TaskSize.self).map(\.rawValue)
        return all.flatMap { c in c.files.map { (c, $0) } }.filter { _, f in
            statuses.contains(f.item.status)
                && (priorities.isEmpty || priorities.contains(f.item.priority))
                && (sizes.isEmpty || sizes.contains(f.item.size))
        }
    }

    private func list(_ args: CLIArgs) throws -> Output {
        let all = try contexts(args)
        var picked = try matching(args, all, defaultStatuses: [.todo, .doing])
        if args.has("ready") { picked = picked.filter { $0.1.item.status == .todo && $0.0.openDepends($0.1.item).isEmpty } }
        let text = picked.map { line($0.1, $0.0, project: args.has("all")) }.joined()
        return output(all, picked, text: text.isEmpty ? "Задач нет\n" : text)
    }

    private func search(_ args: CLIArgs) throws -> Output {
        let words = args.positional.flatMap { $0.split(whereSeparator: \.isWhitespace) }.map { Self.fold(String($0)) }
        guard !words.isEmpty else { throw CLIError.usage("пустой запрос") }
        let all = try contexts(args)
        let picked = try matching(args, all, defaultStatuses: TaskStatus.allCases).filter { _, f in
            let hay = Self.fold(f.item.title + "\n" + f.item.fileName + "\n" + f.item.body)
            return words.allSatisfy { hay.contains($0) }
        }
        let text = picked.map { line($0.1, $0.0, project: args.has("all")) }.joined()
        return output(all, picked, text: text.isEmpty ? "Ничего не найдено\n" : text)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
    }

    private func board(_ args: CLIArgs) throws -> Output {
        let all = try contexts(args)
        let picked = try matching(args, all, defaultStatuses: TaskStatus.allCases)
        let doneShown = 10
        var text = ""
        var columns: [[String: Any]] = []
        for s in TaskStatus.allCases {
            var col = picked.filter { $0.1.item.status == s }
            if s == .done { col.sort { ($0.1.item.completed, $0.1.item.fileName) > ($1.1.item.completed, $1.1.item.fileName) } }
            columns.append(["status": s.rawValue, "title": s.title, "tasks": col.map { json($0.1, $0.0) }])
            text += (text.isEmpty ? "" : "\n") + "\(s.title) (\(col.count))\n"
            let shown = s == .done ? Array(col.prefix(doneShown)) : col
            text += shown.map { "  " + line($0.1, $0.0, project: args.has("all")) }.joined()
            if shown.count < col.count { text += "  … ещё \(col.count - shown.count)\n" }
        }
        let bad = unreadable(all)
        return Output(json: ["columns": columns, "unreadable": bad], text: text,
                      warnings: bad.map { "не читается (или не UTF-8): \($0)" })
    }

    private func show(_ args: CLIArgs) throws -> Output {
        let (ctx, f) = try task(args.positional[0], args)
        let t = f.item
        let blocks = ctx.files.filter { $0.item.depends.contains(t.fileName) }.map(\.item.fileName)
        func items(_ s: MD.Section?) -> [[String: Any]] {
            MD.checklist(t.body, in: s).map {
                let item: [String: Any] = ["n": $0.n + 1, "done": $0.done, "text": $0.text]
                return s == .criteria ? item.merging(["evidence": orNull($0.evidence)]) { $1 } : item
            }
        }
        var j = json(f, ctx)
        j["body"] = t.body
        j["description"] = MD.withoutTasks(t.body)
        j["items"] = items(nil)
        j["criteriaItems"] = items(.criteria)
        j["notes"] = MD.notes(t.body)
        j["blocks"] = blocks
        j["children"] = (ctx.files.map(\.item) + ctx.parked).filter { $0.parent == t.fileName }.map(\.fileName)

        var s = "\(t.title)\n\(f.url.path)\nrev: \(f.rev)\n"
        s += "\(t.status.rawValue), \(t.priority.rawValue)\(t.size.isEmpty ? "" : ", " + t.size), создана \(t.created)"
        s += (t.completed.isEmpty ? "" : ", закрыта \(t.completed)") + "\n"
        let open = Set(ctx.openDepends(t))
        if !t.parent.isEmpty { s += "часть задачи: \(t.parent)\n" }
        for d in t.depends { s += "зависит от: \(d)\(open.contains(d) ? "" : " (готово)")\n" }
        if !t.files.isEmpty { s += "файлы: \(t.files.joined(separator: ", "))\n" }
        if !t.repos.isEmpty { s += "репозитории: \(t.repos.joined(separator: ", "))\n" }
        if !t.verify.isEmpty { s += "проверка: \(t.verify)\n" }
        for b in blocks { s += "блокирует: \(b)\n" }
        for p in t.problems { s += "проблема: \(p.message)\n" }
        // Numbers are what `edit --check N` takes.
        var lines = t.body.components(separatedBy: "\n")
        for (n, i) in MD.taskLines(lines).enumerated() { lines[i] += "  #\(n + 1)" }
        s += "\n" + lines.joined(separator: "\n") + "\n"
        return Output(json: ["task": j], text: clean(s))
    }

    // MARK: Writing commands

    private func text(_ v: String) throws -> String {
        // Under MCP stdin carries the protocol.
        guard v == "-", !confined else { return v }
        guard let s = stdin() else { throw CLIError.usage("--body -: нет данных в stdin (или не UTF-8)") }
        return s
    }

    private func written(_ file: TaskFile, _ ctx: Context, changed: Bool, verb: String) throws -> Output {
        let fresh = try context(ctx.url)
        let f = fresh.files.first { $0.item.fileName == file.item.fileName } ?? file
        return Output(json: ["task": json(f, fresh), "changed": changed],
                      text: clean("\(changed ? verb : "Без изменений"): \(f.item.title)\n\(f.url.path)\n"))
    }

    /// Full file names for `depends:`; every one must exist in the project.
    private func names(_ values: [String], in ctx: Context) throws -> [String] {
        var out: [String] = []
        for v in values.flatMap({ $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }) where !v.isEmpty {
            let n = try dependName(v, in: ctx)
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// A full name may also point to the archive or a draft; parts of names are looked up among active tasks only.
    private func dependName(_ v: String, in ctx: Context) throws -> String {
        let low = v.lowercased()
        func same(_ n: String) -> Bool { [low, low + ".md"].contains(n.lowercased()) }
        if !ctx.files.contains(where: { same($0.item.fileName) }), let p = ctx.parked.first(where: { same($0.fileName) }) {
            return p.fileName
        }
        return try find(v, in: ctx).item.fileName
    }

    private func checkCycle(_ file: String, _ depends: [String], in ctx: Context) throws {
        var graph = Dictionary((ctx.files.map(\.item) + ctx.parked).map { ($0.fileName, $0.depends) }, uniquingKeysWith: { a, _ in a })
        graph[file] = depends
        var seen = Set<String>(), stack = depends
        while let d = stack.popLast() {
            if d == file { throw CLIError.invalid("depends: получится цикл через \(file)") }
            if seen.insert(d).inserted { stack += graph[d] ?? [] }
        }
    }

    private func checkTitle(_ title: String, except file: String?, in ctx: Context, _ args: CLIArgs) throws {
        guard !args.has("force"),
              let twin = ctx.files.first(where: { $0.item.fileName != file
                  && TaskLint.normalized($0.item.title) == TaskLint.normalized(title) }) else { return }
        throw CLIError.invalid("такое название уже у \(twin.item.fileName) (--force — всё равно записать)")
    }

    private func add(_ args: CLIArgs) throws -> Output {
        let ctx = try context(projectURL(args))
        let title = try CLIArgs.line(args.positional[0], "название")
        try checkTitle(title, except: nil, in: ctx, args)
        var body = try text(args.one("body") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for i in try args.lines("item") { body = MD.appendTask(body, i) }
        for c in try args.lines("criterion") { body = MD.appendTask(body, c, in: .criteria) }
        body = DefinitionOfDone.apply(DefinitionOfDone.items(inProject: ctx.url), to: body)
        var t = TaskItem(url: ctx.tasksURL, title: title, status: .todo,
                         priority: try args.choice("priority", Priority.self) ?? .medium,
                         created: Codec.today(), completed: "", body: body)
        t.size = try args.choice("size", TaskSize.self)?.rawValue ?? ""
        t.agent = try agent(args) ?? ""
        t.depends = try names(args.all("depends"), in: ctx)
        t.files = try files(args) ?? []
        t.repos = try repos(args, project: ctx.url) ?? []
        t.verify = try verify(args) ?? ""
        if let p = try args.one("parent") { t.parent = try find(p, in: ctx).item.fileName }
        try checkVerify(t, verify: t.verify, args)
        let file = try TaskFile.create(t, in: ctx.tasksURL) {
            guard !t.parent.isEmpty else { return }
            let now = try context(ctx.url)
            try SubtaskLimit.check(parent: t.parent, (now.files.map(\.item) + now.parked).map { ($0.fileName, $0.parent) })
        }
        return try written(file, ctx, changed: true, verb: "Создана")
    }

    private func change(_ args: CLIArgs, done: Bool) throws -> Output {
        let wants = Set(args.values.keys).subtracting(["project", "if-rev"])
        if !done, wants.isEmpty { throw CLIError.usage("tt edit: не указано, что менять") }
        // Values are checked before the file is read: less time between reading and writing.
        let body = try args.one("body").map { try text($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let (ctx, f) = try task(args.positional[0], args)
        if let rev = try args.one("if-rev"), rev != f.rev {
            throw CLIError.conflict("\(f.item.fileName) изменился: rev \(f.rev), ожидался \(rev)")
        }
        // Rewriting such a file would guess where its fields end.
        if let p = f.item.problems.first(where: { $0.kind == .frontmatter }) {
            throw CLIError.invalid("\(f.item.fileName): \(p.message)")
        }
        var t = f.item
        if let title = try args.line("title"), title != t.title {
            try checkTitle(title, except: t.fileName, in: ctx, args)
            t.title = title
        }
        if let p = try args.choice("priority", Priority.self) { t.priority = p }
        if let v = try args.one("size") { t.size = v == "none" ? "" : try args.choice("size", TaskSize.self)!.rawValue }
        if let v = try agent(args) { t.agent = v }
        try editDepends(&t, args, ctx)
        if let v = try files(args) { t.files = v }
        if let v = try repos(args, project: ctx.url) { t.repos = v }
        let verify = try verify(args)
        if let verify { t.verify = verify }
        try checkVerify(t, verify: verify, args)

        if let body {
            // Otherwise replacing the text would be a way around the criteria check of `done`.
            if confined {
                guard args.values["if-rev"] != nil else { throw CLIError.usage("замена body требует rev из show_task") }
                var left = MD.checklist(body, in: .criteria).map(\.text)
                for c in MD.checklist(t.body, in: .criteria) {
                    guard let i = left.firstIndex(of: c.text) else {
                        throw CLIError.invalid("новый body убирает критерий готовности: \(c.text)")
                    }
                    left.remove(at: i)
                }
            }
            t.body = body
        }
        for (name, on) in [("check", true), ("uncheck", false)] {
            for v in args.all(name).flatMap({ $0.split(separator: ",") }) {
                let lines = t.body.components(separatedBy: "\n")
                let idx = MD.taskLines(lines)
                guard let n = Int(v), n >= 1, n <= idx.count else {
                    throw CLIError.usage("--\(name) \(v): есть пункты 1…\(idx.count), см. tt show")
                }
                let l = lines[idx[n - 1]].trimmingCharacters(in: .whitespaces).lowercased()
                let isOn = l.hasPrefix("- [x]") || l.hasPrefix("* [x]")
                if isOn != on { t.body = MD.toggleTask(t.body, n - 1) }
            }
        }
        for i in try args.lines("item") { t.body = MD.appendTask(t.body, i) }
        for c in try args.lines("criterion") { t.body = MD.appendTask(t.body, c, in: .criteria) }
        for n in try args.lines("note") { t.body = MD.appendNote(t.body, n) }

        let status = done ? .done : try args.choice("status", TaskStatus.self)
        if let status {
            if status == .done, t.status != .done, !args.has("force") {
                let open = MD.checklist(t.body, in: .criteria).filter { !$0.done }
                if !open.isEmpty {
                    throw CLIError.invalid("не выполнены критерии готовности (--force — всё равно закрыть): "
                        + open.map { "#\($0.n + 1) \($0.text)" }.joined(separator: "; "))
                }
            }
            t.status = status
            if status != .done { t.completed = "" } else if t.completed.isEmpty { t.completed = Codec.today() }
        }

        var new = Codec.serialize(t, updating: f.text)
        // A bad value in the file parses as the default, so setting that default looks like no change.
        let fields = Frontmatter.parse(f.text).fields
        func fix(_ key: String, _ value: String, when: Bool) {
            let old = Frontmatter.word(fields[key])
            if when, old != value, Frontmatter.word(Frontmatter.parse(new).fields[key]) != value {
                new = Frontmatter.setting(key, to: value, in: new)
            }
        }
        fix("status", t.status.rawValue, when: status != nil)
        fix("priority", t.priority.rawValue, when: wants.contains("priority"))
        fix("size", t.size, when: wants.contains("size"))

        // A field that can't be read parses as no field.
        if let verify {
            let wanted = verify.isEmpty ? TaskVerify.none : .command(verify)
            if TaskVerify.parse(new) != wanted { new = TaskVerify.setting(verify, in: new) }
            if TaskVerify.parse(new) != wanted { throw CLIError.invalid("\(f.item.fileName): verify записано в несколько строк — поправь файл") }
        }

        let changed = new == f.text.replacingOccurrences(of: "\r\n", with: "\n") ? false : try f.write(new)
        return try written(f, ctx, changed: changed, verb: done ? "Закрыта" : "Изменена")
    }

    /// `--agent`: profile name; "none" = the default profile. Which profiles exist is known only to the app.
    private func agent(_ args: CLIArgs) throws -> String? {
        guard let v = try args.one("agent")?.lowercased() else { return nil }
        if v == "none" { return "" }
        guard AgentProfile.isValidID(v) else { throw CLIError.usage("--agent \(v): нужно имя профиля, например claude") }
        return v
    }

    /// `--files`: the whole list; "none" = empty.
    private func files(_ args: CLIArgs) throws -> [String]? {
        guard let v = try args.one("files") else { return nil }
        if v == "none" { return [] }
        let out = TaskFiles.split(v)
        guard !out.isEmpty else { throw CLIError.usage("--files: нужен хотя бы один путь или none") }
        for p in out where !TaskFiles.isWritable(p) {
            throw CLIError.usage("--files \(p): нужен путь внутри проекта: относительный, без «..», «*», кавычек и «#»")
        }
        return out
    }

    /// `--repos`: the whole list; "none" = empty. The app checks it again against its own projects root.
    private func repos(_ args: CLIArgs, project: URL) throws -> [String]? {
        guard let v = try args.one("repos") else { return nil }
        if v == "none" { return [] }
        let out = TaskFiles.split(v)
        guard !out.isEmpty else { throw CLIError.usage("--repos: нужен хотя бы один путь или none") }
        for p in out where !TaskRepos.isValid(p) {
            throw CLIError.usage("--repos \(p): нужен путь папки без «~», «*», кавычек и «#»")
        }
        if case .failure(let f) = TaskRepos.resolve(out, root: root, project: project) { throw CLIError.invalid(f.message) }
        return out
    }

    /// `--verify`: command of the task's own check; "none" = no field. Approved only in the app.
    private func verify(_ args: CLIArgs) throws -> String? {
        guard let v = try args.one("verify")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if v == "none" { return "" }
        if let why = TaskVerify.problem(v) { throw CLIError.usage("--verify: \(why)") }
        return v
    }

    private func checkVerify(_ t: TaskItem, verify: String?, _ args: CLIArgs) throws {
        guard verify?.isEmpty == false || args.values["repos"] != nil, !t.verify.isEmpty, !t.repos.isEmpty else { return }
        throw CLIError.invalid("verify не совместимо с repos: одна команда не относится к каждому репозиторию")
    }

    private func editDepends(_ t: inout TaskItem, _ args: CLIArgs, _ ctx: Context) throws {
        let old = t.depends
        if let v = try args.one("depends") { t.depends = v == "none" ? [] : try names([v], in: ctx) }
        for n in try names(args.all("add-depend"), in: ctx) where !t.depends.contains(n) { t.depends.append(n) }
        for v in args.all("rm-depend").flatMap({ $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }) {
            // A broken reference is removed by its literal name: there is no such file to find.
            let name = t.depends.contains(v) ? v : try find(v, in: ctx).item.fileName
            guard t.depends.contains(name) else { throw CLIError.notFound("--rm-depend \(v): такой зависимости нет") }
            t.depends.removeAll { $0 == name }
        }
        if t.depends != old { try checkCycle(t.fileName, t.depends, in: ctx) }
    }
}

enum TaskSize: String, CaseIterable { case s, m, l }
