import Foundation

// UI-only parts (colors, templates) live in the app target as extensions.

public enum TaskStatus: String, CaseIterable, Identifiable, Sendable {
    case todo, doing, done
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .todo: "К выполнению"
        case .doing: "В работе"
        case .done: "Готово"
        }
    }

    public var icon: String {
        switch self {
        case .todo: "circle"
        case .doing: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }
}

public enum Priority: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    public var id: String { rawValue }
    /// 0 low, 1 medium, 2 high: for comparing priorities.
    public var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public var title: String {
        switch self {
        case .low: "Низкий"
        case .medium: "Средний"
        case .high: "Высокий"
        }
    }
}

public enum ProjectStatus: String, CaseIterable, Identifiable, Sendable {
    case active, paused, archived, unknown
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .active: "Активный"
        case .paused: "На паузе"
        case .archived: "Архив"
        case .unknown: "Неизвестно"
        }
    }
}

public struct TaskItem: Identifiable, Hashable, Sendable {
    public var url: URL
    public var id: String { url.path }
    public var title: String
    public var status: TaskStatus
    public var priority: Priority
    public var created: String
    public var completed: String
    public var body: String
    /// File names of tasks (same project) that must be done first. Frontmatter `depends:`.
    public var depends: [String] = []
    /// Frontmatter `parent:` — file name of the task (same project) this one is a part of, "" when none.
    /// Says nothing about the order of work: only `depends` does.
    public var parent = ""
    /// Frontmatter `files:` — files and folders the task will change, as written (`TaskFiles`).
    public var files: [String] = []
    /// Frontmatter `repos:` — other repositories the task changes too, as written (`TaskRepos`).
    public var repos: [String] = []
    /// Frontmatter `verify:` — command of the task's own check (`TaskVerify`), "" when none or not valid.
    public var verify = ""
    /// Estimate: "s", "m", "l" or "". Frontmatter `size:`.
    public var size = ""
    /// Frontmatter `plan: true`: the agent first writes «## План» and waits for approval.
    public var plan = false
    /// `plan: false`: no plan even for a large task.
    public var planOff = false
    /// Frontmatter `source:`: URL of the GitHub issue the task was imported from. Its text is untrusted.
    public var source = ""
    /// Frontmatter `automation:` — file of the schedule that created the task. Such work is never merged automatically.
    public var automation = ""
    /// Frontmatter `worktree: never`: the task runs in the main folder even when the project always uses worktrees.
    public var mainFolderOnly = false
    /// Frontmatter `milestone:` — name of the release or stage the task belongs to, "" when none.
    public var milestone = ""
    /// Frontmatter `agent:` — agent profile that does the task, "" = the default one.
    public var agent = ""
    /// Frontmatter `workflow:` — pipeline `workflows/<name>.md` that does the task, "" = none.
    public var workflow = ""
    /// Lint results (`TaskLint`): bad fields, broken depends, duplicates. Not serialized.
    public var problems: [TaskProblem] = []

    public var fileName: String { url.lastPathComponent }

    public init(url: URL, title: String, status: TaskStatus, priority: Priority, created: String,
                completed: String, body: String, depends: [String] = [], size: String = "") {
        self.url = url
        self.title = title
        self.status = status
        self.priority = priority
        self.created = created
        self.completed = completed
        self.body = body
        self.depends = depends
        self.size = size
    }
}

public struct Project: Identifiable, Hashable, Sendable {
    public let url: URL
    public var id: String { url.path }
    public let folderName: String
    public let category: String
    public var displayName: String
    public var stack: [String]
    public var status: ProjectStatus
    public var updated: String
    public var summary: String
    public var aboutBody: String
    public var hasAbout: Bool
    public var tasks: [TaskItem]
    /// `tasks/archive/` (read only) and `tasks/drafts/`.
    public var archive: [TaskItem] = []
    public var drafts: [TaskItem] = []
    /// Schedules: `automations/*.md`.
    public var automations: [Automation] = []
    /// Event rules: the same folder, files with `on:`.
    public var eventRules: [EventRule] = []
    /// about.md `verify:` — command run after background tasks (e.g. `pnpm typecheck`).
    public var verify = ""
    /// about.md `worktree: always`: every new code task gets its own worktree.
    public var alwaysWorktree = false
    /// about.md `executor: docker`.
    public var inDocker = false
    /// about.md `## Definition of Done` — items added to the criteria of new tasks.
    public var dod: [String] = []
    /// spectrack.md text ("" when missing) and its file name as it is on disk (may be SPECTRACK.md).
    public var spec = ""
    public var hasSpec = false
    public var specName = SpecDoc.fileName
    /// `workflows/*.md` of the project.
    public var workflows: [WorkflowFile] = []

    public var openCount: Int { tasks.filter { $0.status != .done }.count }
    public var doingCount: Int { tasks.filter { $0.status == .doing }.count }
    public var tasksURL: URL { url.appendingPathComponent("tasks", isDirectory: true) }
    public var aboutURL: URL { url.appendingPathComponent("about.md") }
    public var specURL: URL { url.appendingPathComponent(specName) }

    public init(url: URL, folderName: String, category: String, displayName: String, stack: [String],
                status: ProjectStatus, updated: String, summary: String, aboutBody: String,
                hasAbout: Bool, tasks: [TaskItem], verify: String = "") {
        self.url = url
        self.folderName = folderName
        self.category = category
        self.displayName = displayName
        self.stack = stack
        self.status = status
        self.updated = updated
        self.summary = summary
        self.aboutBody = aboutBody
        self.hasAbout = hasAbout
        self.tasks = tasks
        self.verify = verify
    }
}

// MARK: - Frontmatter

public enum Frontmatter {
    public static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], text) }
        var fields: [String: String] = [:]
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields[key] = unquote(value)
            }
            i += 1
        }
        guard i < lines.count else { return ([:], text) }
        let body = i + 1 < lines.count ? lines[(i + 1)...].joined(separator: "\n") : ""
        return (fields, body)
    }

    public static func unquote(_ v: String) -> String {
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
            return String(v.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return v
    }

    public static func quote(_ v: String) -> String {
        let esc = v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(esc)\""
    }

    /// Replace, add or (empty value) remove `key:` in the frontmatter; creates frontmatter if missing.
    /// A trailing ` # comment` of the replaced line is kept. `keepBare`: empty value leaves `key:` instead of removing the line.
    public static func setting(_ key: String, to value: String, in text: String, defaults: [String] = [],
                               keepBare: Bool = false) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) != "---"
            || !lines.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = ["---"] + defaults + ["---", ""] + (text.isEmpty ? [] : lines)
        }
        let end = lines.indices.dropFirst().first { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }!
        let line = value.isEmpty ? "\(key):" : "\(key): \(value)"
        if let i = lines[1..<end].firstIndex(where: { $0.hasPrefix(key + ":") }) {
            if value.isEmpty && !keepBare { lines.remove(at: i); return lines.joined(separator: "\n") }
            let old = String(lines[i].dropFirst(key.count + 1))
            let comment = trailingComment(old)
            lines[i] = comment.isEmpty ? line : line + " " + comment
        } else if !value.isEmpty || keepBare {
            lines.insert(line, at: end)
        }
        return lines.joined(separator: "\n")
    }

    /// Index where a ` # comment` starts (quoted values are skipped), or nil.
    private static func commentStart(_ v: String) -> String.Index? {
        var i = v.startIndex
        var inQuote = false
        var prevSpace = true
        while i < v.endIndex {
            let c = v[i]
            if inQuote {
                if c == "\\" { i = v.index(after: i); if i == v.endIndex { break } }
                else if c == "\"" { inQuote = false }
            } else if c == "\"" {
                inQuote = true
            } else if c == "#" && prevSpace {
                return i
            }
            prevSpace = (c == " " || c == "\t")
            i = v.index(after: i)
        }
        return nil
    }

    /// Value without a trailing ` # comment` (trimmed).
    public static func stripComment(_ v: String) -> String {
        let cut = commentStart(v).map { String(v[..<$0]) } ?? v
        return cut.trimmingCharacters(in: .whitespaces)
    }

    private static func trailingComment(_ v: String) -> String {
        commentStart(v).map { String(v[$0...]).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Text of the `key:` line as written (trailing ` # comment` dropped, quotes kept), or nil.
    /// Unlike `parse`, keeps a ` #` inside quotes apart from a comment. Same line as `setting` rewrites.
    public static func raw(_ key: String, in text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }),
              let line = lines[1..<end].first(where: { $0.hasPrefix(key + ":") }) else { return nil }
        return stripComment(String(line.dropFirst(key.count + 1)))
    }

    /// Value without trailing `# comment`.
    public static func word(_ v: String?) -> String {
        guard let v else { return "" }
        return stripComment(v).lowercased()
    }

    public static func list(_ v: String?) -> [String] {
        guard var v = v.map({ stripComment($0) }), !v.isEmpty else { return [] }
        if v.hasPrefix("[") { v.removeFirst() }
        if v.hasSuffix("]") { v.removeLast() }
        return v.split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Parsing / serializing

public enum Codec {
    public static func project(at url: URL, category: String) -> Project {
        let aboutURL = url.appendingPathComponent("about.md")
        var p = Project(
            url: url, folderName: url.lastPathComponent, category: category,
            displayName: url.lastPathComponent, stack: [], status: .unknown,
            updated: "", summary: "", aboutBody: "", hasAbout: false, tasks: []
        )
        if let text = try? String(contentsOf: aboutURL, encoding: .utf8) {
            let (f, body) = Frontmatter.parse(text)
            p.hasAbout = true
            if let n = f["name"], !n.isEmpty { p.displayName = n }
            p.stack = Frontmatter.list(f["stack"])
            p.status = ProjectStatus(rawValue: Frontmatter.word(f["status"])) ?? .unknown
            p.updated = Frontmatter.word(f["updated"])
            p.verify = (f["verify"] ?? "").trimmingCharacters(in: .whitespaces)
            p.alwaysWorktree = Frontmatter.word(f["worktree"]) == "always"
            p.inDocker = Frontmatter.word(f["executor"]) == Executor.docker.rawValue
            p.aboutBody = body
            p.dod = DefinitionOfDone.items(inAbout: text)
            p.summary = firstParagraph(body)
        }
        let specURL = SpecDoc.url(in: url)
        p.specName = specURL.lastPathComponent
        if FileManager.default.fileExists(atPath: specURL.path) {
            p.hasSpec = true
            p.spec = (try? String(contentsOf: specURL, encoding: .utf8)) ?? ""
        }
        p.workflows = WorkflowFile.all(in: url)
        for f in TaskFolder.allCases { p[f] = rawTasks(in: f.url(in: p.tasksURL)) }
        for f in Automation.files(in: url) {
            guard let text = Automation.text(of: f) else { continue }
            if EventRule.isRule(text) { p.eventRules.append(EventRule.parse(text, url: f)) }
            else if let a = Automation.read(text, url: f) { p.automations.append(a) }
        }
        TaskLint.crossCheck(&p)
        return p
    }

    public static func firstParagraph(_ body: String) -> String {
        var collected: [String] = []
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix("---") {
                if !collected.isEmpty { break } else { continue }
            }
            if line.isEmpty {
                if !collected.isEmpty { break } else { continue }
            }
            collected.append(line)
        }
        return collected.joined(separator: " ")
    }

    /// Active tasks of a `tasks/` folder, checked against its archive and drafts.
    public static func tasks(in dir: URL) -> [TaskItem] {
        var out = rawTasks(in: dir)
        TaskLint.crossCheck(&out, others: rawTasks(in: TaskFolder.archive.url(in: dir)) + rawTasks(in: TaskFolder.drafts.url(in: dir)))
        return out
    }

    /// Files of exactly this folder, without cross-file checks.
    static func rawTasks(in dir: URL) -> [TaskItem] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap(task(at:))
            .sorted { ($0.priorityRank, $0.created, $0.fileName) < ($1.priorityRank, $1.created, $1.fileName) }
    }

    public static func task(at url: URL) -> TaskItem? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return task(from: text, url: url)
    }

    /// Parses task file contents (`url` only names the task).
    public static func task(from text: String, url: URL) -> TaskItem {
        let (f, body) = Frontmatter.parse(text)
        let title: String = {
            if let t = f["title"], !t.isEmpty { return t }
            if let h = body.components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") }) {
                return String(h.dropFirst(2))
            }
            return url.deletingPathExtension().lastPathComponent
        }()
        var t = TaskItem(
            url: url,
            title: title,
            status: TaskStatus(rawValue: Frontmatter.word(f["status"])) ?? .todo,
            priority: Priority(rawValue: Frontmatter.word(f["priority"])) ?? .medium,
            created: Frontmatter.word(f["created"]),
            completed: Frontmatter.word(f["completed"]),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        t.depends = Frontmatter.list(f["depends"])
        t.parent = Frontmatter.unquote(Frontmatter.stripComment(f["parent"] ?? ""))
        t.files = Frontmatter.list(f["files"])
        t.repos = Frontmatter.list(f["repos"])
        t.verify = TaskVerify.parse(text).command
        t.size = ["s", "m", "l"].contains(Frontmatter.word(f["size"])) ? Frontmatter.word(f["size"]) : ""
        t.plan = ["true", "yes", "да"].contains(Frontmatter.word(f["plan"]))
        t.planOff = ["false", "no", "нет"].contains(Frontmatter.word(f["plan"]))
        t.source = Frontmatter.unquote((f["source"] ?? "").trimmingCharacters(in: .whitespaces))
        t.automation = Frontmatter.unquote(Frontmatter.stripComment(f["automation"] ?? ""))
        t.mainFolderOnly = Frontmatter.word(f["worktree"]) == "never"
        t.agent = Frontmatter.word(f["agent"])
        t.workflow = Frontmatter.word(f["workflow"])
        t.milestone = Milestone.parse(Frontmatter.raw("milestone", in: text))
        t.problems = TaskLint.fileProblems(text: text, fileName: url.lastPathComponent)
        return t
    }

    /// Canonical task file: fixed key order, no trailing spaces (`completed:` stays bare when empty).
    public static func serialize(_ t: TaskItem) -> String {
        """
        ---
        title: \(Frontmatter.quote(t.title))
        status: \(t.status.rawValue)
        priority: \(t.priority.rawValue)
        created: \(t.created)
        completed:\(t.completed.isEmpty ? "" : " " + t.completed)\(t.size.isEmpty ? "" : "\nsize: " + t.size)\(t.plan ? "\nplan: true" : t.planOff ? "\nplan: false" : "")\(t.mainFolderOnly ? "\nworktree: never" : "")\(t.agent.isEmpty ? "" : "\nagent: " + t.agent)\(t.workflow.isEmpty ? "" : "\nworkflow: " + t.workflow)\(t.source.isEmpty ? "" : "\nsource: " + t.source)\(t.automation.isEmpty ? "" : "\nautomation: " + t.automation)\(Milestone.clean(t.milestone).isEmpty ? "" : "\nmilestone: " + Frontmatter.quote(Milestone.clean(t.milestone)))\(t.parent.isEmpty ? "" : "\nparent: " + t.parent)\(t.depends.isEmpty ? "" : "\ndepends: [" + t.depends.joined(separator: ", ") + "]")\(t.files.isEmpty ? "" : "\nfiles: [" + t.files.joined(separator: ", ") + "]")\(t.repos.isEmpty ? "" : "\nrepos: [" + t.repos.joined(separator: ", ") + "]")\(t.verify.isEmpty ? "" : "\nverify: " + Frontmatter.quote(t.verify))
        ---

        \(t.body)

        """
    }

    /// Rewrite `original` file text in place: only lines of changed fields are touched, comments and
    /// unknown fields stay. Body is kept verbatim when its content is unchanged.
    public static func serialize(_ t: TaskItem, updating original: String) -> String {
        let (f, oldBody) = Frontmatter.parse(original)
        guard !f.isEmpty || original.hasPrefix("---") else { return serialize(t) }
        let old = task(from: original, url: t.url)
        var text = original.replacingOccurrences(of: "\r\n", with: "\n")
        func set(_ key: String, _ value: String, bare: Bool = false) {
            text = Frontmatter.setting(key, to: value, in: text, keepBare: bare)
        }
        if old.title != t.title || f["title"] == nil { set("title", Frontmatter.quote(t.title)) }
        if old.status != t.status || f["status"] == nil { set("status", t.status.rawValue) }
        if old.priority != t.priority || f["priority"] == nil { set("priority", t.priority.rawValue) }
        if old.created != t.created || f["created"] == nil { set("created", t.created) }
        if old.completed != t.completed || f["completed"] == nil { set("completed", t.completed, bare: true) }
        if old.size != t.size { set("size", t.size) }
        if old.plan != t.plan { set("plan", t.plan ? "true" : "") }
        if old.mainFolderOnly != t.mainFolderOnly { set("worktree", t.mainFolderOnly ? "never" : "") }
        if old.agent != t.agent { set("agent", t.agent) }
        if old.workflow != t.workflow { set("workflow", t.workflow) }
        if old.source != t.source { set("source", t.source) }
        if old.automation != t.automation { set("automation", t.automation) }
        let milestone = Milestone.clean(t.milestone)
        if old.milestone != milestone { set("milestone", milestone.isEmpty ? "" : Frontmatter.quote(milestone)) }
        if old.parent != t.parent { set("parent", t.parent) }
        if old.depends != t.depends { set("depends", t.depends.isEmpty ? "" : "[" + t.depends.joined(separator: ", ") + "]") }
        if old.files != t.files { set("files", t.files.isEmpty ? "" : "[" + t.files.joined(separator: ", ") + "]") }
        if old.repos != t.repos { set("repos", t.repos.isEmpty ? "" : "[" + t.repos.joined(separator: ", ") + "]") }
        if !TaskVerify.same(old.verify, t.verify) { text = TaskVerify.setting(t.verify, in: text) }
        if oldBody.trimmingCharacters(in: .whitespacesAndNewlines) != t.body.trimmingCharacters(in: .whitespacesAndNewlines) {
            let lines = text.components(separatedBy: "\n")
            if let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) {
                text = (lines[...end] + ["", t.body, ""]).joined(separator: "\n")
            }
        }
        return text
    }

    public static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    public static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    public static func slug(_ s: String) -> String {
        let latin = s.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? s
        var out = ""
        for ch in latin.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) }
            else if !out.hasSuffix("-") { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

extension TaskItem {
    public var priorityRank: Int {
        switch priority {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }
}
