import Foundation

/// A problem in a task file that the parser would otherwise silently swallow.
public struct TaskProblem: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// No frontmatter or no closing `---`.
        case frontmatter
        /// Unknown value of `status` / `priority` / `size`, or a malformed date.
        case field(String)
        /// `status: done` without `completed:` — quick fix fills in the date.
        case missingCompleted
        /// File name is not `YYYYMMDD-HHMMSS-slug.md`.
        case fileName
        /// `depends:` names a file that does not exist in tasks/ — quick fix drops it.
        case brokenDepend(String)
        /// `depends:` names an unfinished task of the archive or a draft: nobody will do it there.
        case parkedDepend(String)
        /// `parent:` names a missing file, the task itself, or leads into a cycle.
        case badParent(String)
        /// `repos:` leads outside the projects root or not to a repository (`TaskRepos.lint`).
        case badRepo
        /// The archive or drafts have a file with the same name.
        case nameClash(TaskFolder)
        /// Another task in the project has the same title.
        case duplicate(String)

        /// Needs the other tasks of the project (recomputed by `TaskLint.crossCheck`).
        public var isCross: Bool {
            switch self {
            case .brokenDepend, .parkedDepend, .badParent, .nameClash, .duplicate: true
            default: false
            }
        }
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum TaskLint {
    static let statuses = TaskStatus.allCases.map(\.rawValue)
    static let priorities = Priority.allCases.map(\.rawValue)
    static let sizes = ["s", "m", "l"]

    /// Checks that need only this file: frontmatter, field values, done ⇒ completed, file name.
    public static func fileProblems(text: String, fileName: String) -> [TaskProblem] {
        var out: [TaskProblem] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) != "---" {
            out.append(TaskProblem(.frontmatter, "Нет frontmatter (файл должен начинаться с ---)"))
        } else if !lines.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            out.append(TaskProblem(.frontmatter, "Frontmatter не закрыт (нет второй строки ---)"))
        } else {
            let f = Frontmatter.parse(text).fields
            let status = Frontmatter.word(f["status"])
            if status.isEmpty {
                out.append(TaskProblem(.field("status"), "Нет поля status (todo | doing | done)"))
            } else if !statuses.contains(status) {
                out.append(TaskProblem(.field("status"), "status: \(status) — допустимо todo | doing | done"))
            }
            let priority = Frontmatter.word(f["priority"])
            if !priority.isEmpty, !priorities.contains(priority) {
                out.append(TaskProblem(.field("priority"), "priority: \(priority) — допустимо low | medium | high"))
            }
            let size = Frontmatter.word(f["size"])
            if !size.isEmpty, !sizes.contains(size) {
                out.append(TaskProblem(.field("size"), "size: \(size) — допустимо s | m | l"))
            }
            let worktree = Frontmatter.word(f["worktree"])
            if !worktree.isEmpty, worktree != "never" {
                out.append(TaskProblem(.field("worktree"), "worktree: \(worktree) — в задаче допустимо только never"))
            }
            let executor = Frontmatter.word(f["executor"])
            if !executor.isEmpty, Executor(rawValue: executor) == nil {
                out.append(TaskProblem(.field("executor"), "executor: \(executor) — допустимо local | docker"))
            }
            if executor == Executor.docker.rawValue, worktree == "never" {
                out.append(TaskProblem(.field("executor"), "executor: docker работает только в worktree, а в задаче worktree: never"))
            }
            // Which profiles exist is known only to the app; here only the form is checked.
            let agent = Frontmatter.word(f["agent"])
            if !agent.isEmpty, !AgentProfile.isValidID(agent) {
                out.append(TaskProblem(.field("agent"), "agent: \(agent) — нужно имя профиля, например claude"))
            }
            let workflow = Frontmatter.word(f["workflow"])
            if !workflow.isEmpty, !AgentProfile.isValidID(workflow) {
                out.append(TaskProblem(.field("workflow"), "workflow: \(workflow) — нужно имя файла из workflows/ без .md"))
            }
            if let raw = Frontmatter.raw("milestone", in: text), Milestone.isMalformed(raw) {
                out.append(TaskProblem(.field("milestone"), "milestone: \(raw) — нужна одна строка, например \"v1.0\""))
            }
            for p in Frontmatter.list(f["files"]) where !TaskFiles.isValid(p) {
                out.append(TaskProblem(.field("files"), "files: \(p) — нужен путь внутри проекта: относительный, без «..» и «*»"))
            }
            let repos = Frontmatter.list(f["repos"])
            for p in repos where !TaskRepos.isValid(p) {
                out.append(TaskProblem(.field("repos"), "repos: \(p) — нужен путь папки без «~», «*», кавычек и «#»"))
            }
            if !repos.isEmpty, worktree == "never" {
                out.append(TaskProblem(.field("repos"), "repos не совместимо с worktree: never — такая задача всегда идёт в worktree"))
            }
            let verify = TaskVerify.parse(text)
            if case .invalid(let why, _) = verify {
                out.append(TaskProblem(.field("verify"), "verify: \(why)"))
            }
            if verify != .none, !repos.isEmpty {
                out.append(TaskProblem(.field("verify"), "verify не совместимо с repos: одна команда не относится к каждому репозиторию"))
            }
            for key in ["created", "completed"] {
                let v = Frontmatter.word(f[key])
                if !v.isEmpty, !isDate(v) {
                    out.append(TaskProblem(.field(key), "\(key): \(v) — нужна дата YYYY-MM-DD"))
                }
            }
            if status == TaskStatus.done.rawValue, Frontmatter.word(f["completed"]).isEmpty {
                out.append(TaskProblem(.missingCompleted, "status: done, но completed не заполнен"))
            }
        }
        if !isValidFileName(fileName) {
            out.append(TaskProblem(.fileName, "Имя файла не по формату YYYYMMDD-HHMMSS-slug.md"))
        }
        return out
    }

    /// All folders of a project: active tasks and drafts. The archive is read only, so it gets no cross-checks.
    public static func crossCheck(_ p: inout Project) {
        crossCheck(&p.tasks, others: p.archive + p.drafts)
        crossCheck(&p.drafts, others: p.tasks + p.archive)
    }

    /// Replaces cross-task problems (broken depends, duplicate titles) for every task of one folder.
    /// `others`: tasks of the project's other folders, which `depends:` may point to as well.
    public static func crossCheck(_ tasks: inout [TaskItem], others: [TaskItem] = []) {
        let outside = Dictionary(others.map { ($0.fileName, $0) }, uniquingKeysWith: { a, _ in a })
        let names = Set(tasks.map(\.fileName))
        let parents = SubtaskLimit.parents((tasks + others).map { ($0.fileName, $0.parent) })
        var byTitle: [String: [String]] = [:]
        for t in tasks { byTitle[normalized(t.title), default: []].append(t.fileName) }
        for i in tasks.indices {
            var p = tasks[i].problems.filter { !$0.kind.isCross }
            for d in tasks[i].depends {
                if d == tasks[i].fileName {
                    p.append(TaskProblem(.brokenDepend(d), "depends ссылается на саму задачу: \(d)"))
                } else if !names.contains(d) {
                    if let o = outside[d] {
                        if o.folder != .active, !o.satisfiesDepends, tasks[i].folder != .drafts || o.folder != .drafts {
                            p.append(TaskProblem(.parkedDepend(d), o.folder == .drafts
                                ? "depends: \(d) — черновик" : "depends: \(d) в архиве, но не выполнена"))
                        }
                    } else {
                        p.append(TaskProblem(.brokenDepend(d), "depends: нет файла \(d)"))
                    }
                }
            }
            if let m = SubtaskLimit.parentProblem(tasks[i].fileName, parents) {
                p.append(TaskProblem(.badParent(tasks[i].parent), m))
            }
            if let o = outside[tasks[i].fileName] {
                p.append(TaskProblem(.nameClash(o.folder), "Файл с таким именем есть и в разделе «\(o.folder.title)»"))
            }
            let twins = (byTitle[normalized(tasks[i].title)] ?? []).filter { $0 != tasks[i].fileName }
            if let other = twins.first {
                p.append(TaskProblem(.duplicate(other), "Дубль: такое же название у \(other)"))
            }
            tasks[i].problems = p
        }
    }

    public static func isValidFileName(_ name: String) -> Bool {
        name.range(of: #"^\d{8}-\d{6}(-[a-z0-9]+(-[a-z0-9]+)*)?\.md$"#, options: .regularExpression) != nil
    }

    static func isDate(_ v: String) -> Bool {
        v.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
