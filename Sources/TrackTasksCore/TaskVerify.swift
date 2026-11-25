import Foundation

/// Frontmatter `verify:` of a task: its own check, run after the project's one and never instead of it.
/// An agent can edit the task file, so the command runs only after a person approved exactly its text.
public enum TaskVerify: Equatable, Sendable {
    case none
    case command(String)
    /// Can't be read for certain: refused, never taken for «no field». `raw` — what is written.
    case invalid(String, raw: String)

    public var command: String { if case .command(let c) = self { c } else { "" } }

    /// The field as written; "" when there is none. Remembered when the task is queued.
    public var text: String {
        switch self {
        case .none: ""
        case .command(let c): c
        case .invalid(_, let raw): raw.isEmpty ? "?" : raw
        }
    }

    /// Byte by byte: for `String` a letter and its decomposed form are equal, for a shell they aren't.
    public static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    // MARK: Parsing

    /// Lines of the field in the frontmatter, with the same idea of a key as `Frontmatter.parse`.
    private static func find(_ lines: [String]) -> [Int] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) else { return [] }
        return (1..<end).filter { i in
            lines[i].firstIndex(of: ":").map { lines[i][..<$0].trimmingCharacters(in: .whitespaces).lowercased() == "verify" } ?? false
        }
    }

    private static func split(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    public static func parse(_ text: String) -> TaskVerify {
        let lines = split(text), found = find(lines)
        guard let i = found.first else { return .none }
        let line = lines[i]
        let raw = line[line.index(after: line.firstIndex(of: ":")!)...].trimmingCharacters(in: .whitespaces)
        func bad(_ why: String) -> TaskVerify { .invalid(why, raw: raw) }
        if found.count > 1 { return bad("поле указано несколько раз") }
        if hasInvisible(line) { return bad("управляющие или невидимые символы") }
        if let next = lines[i + 1].first, next == " " || next == "\t" || lines[i + 1].hasPrefix("- ") { return bad("нужна одна строка") }
        guard let first = raw.first else { return .none }
        if first == "|" || first == ">" { return bad("нужна одна строка, без «|» и «>»") }
        if first == "\"" || first == "'" {
            guard let v = quoted(raw) else { return bad("кавычки не закрыты, или после них есть текст: возьми команду в кавычки целиком") }
            let c = v.trimmingCharacters(in: .whitespaces)
            return c.isEmpty ? .none : .command(c)
        }
        guard let v = plain(raw) else { return bad("кавычки не закрыты") }
        return v.isEmpty ? .none : .command(v)
    }

    /// Why the value can't be a command; nil — it can.
    public static func problem(_ command: String) -> String? {
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return "пустая команда" }
        if command.contains(where: \.isNewline) { return "нужна одна строка" }
        return hasInvisible(command) ? "управляющие или невидимые символы" : nil
    }

    private static func hasInvisible(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            if u == " " { return false }
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .privateUse, .unassigned, .surrogate: return true
            default: return u.properties.isDefaultIgnorableCodePoint
            }
        }
    }

    /// Whole value in quotes, then nothing but a comment; nil — it isn't so.
    private static func quoted(_ s: String) -> String? {
        let u = Array(s.unicodeScalars), q = u[0]
        var out = String.UnicodeScalarView(), i = 1
        while i < u.count {
            if q == "\"", u[i] == "\\", i + 1 < u.count, u[i + 1] == "\"" || u[i + 1] == "\\" {
                out.append(u[i + 1])
                i += 2
            } else if q == "'", u[i] == "'", i + 1 < u.count, u[i + 1] == "'" {
                out.append("'")
                i += 2
            } else if u[i] == q {
                let rest = u[(i + 1)...]
                guard rest.isEmpty || (rest.first == " " && [nil, "#"].contains(rest.first { $0 != " " })) else { return nil }
                return String(out)
            } else {
                out.append(u[i])
                i += 1
            }
        }
        return nil
    }

    /// Cut at ` #` outside quotes; nil — quotes of the command aren't closed.
    private static func plain(_ s: String) -> String? {
        let u = Array(s.unicodeScalars)
        var q: Unicode.Scalar?, i = 0, cut = u.count
        while i < u.count {
            if u[i] == "\\", q != "'" { i += 2; continue }
            if let open = q {
                if u[i] == open { q = nil }
            } else if u[i] == "\"" || u[i] == "'" {
                q = u[i]
            } else if u[i] == "#", i == 0 || u[i - 1] == " " {
                cut = i
                break
            }
            i += 1
        }
        guard q == nil else { return nil }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: u[..<cut])
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    /// The field of a file changed to `command` ("" = removed); every other way it was written goes away.
    public static func setting(_ command: String, in text: String) -> String {
        var lines = split(text)
        let extra = find(lines).filter { !lines[$0].hasPrefix("verify:") }
        for i in extra.reversed() { lines.remove(at: i) }
        for i in find(lines).dropFirst().reversed() { lines.remove(at: i) }
        // The old line is not parsed for its comment: in a command `#` may be anything.
        if let i = find(lines).first { lines[i] = "verify:" }
        return Frontmatter.setting("verify", to: command.isEmpty ? "" : Frontmatter.quote(command), in: lines.joined(separator: "\n"))
    }

    // MARK: The file

    /// The task's field now, wherever the file has been moved (archive); nil — there is no such file.
    public static func load(taskAt url: URL) -> TaskVerify? {
        let tasks = TaskFolder(of: url) == .active ? url.deletingLastPathComponent() : url.deletingLastPathComponent().deletingLastPathComponent()
        for f in [TaskFolder.active, .archive] {
            let u = f.url(in: tasks).appendingPathComponent(url.lastPathComponent)
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { return .invalid("файл задачи не читается", raw: "") }
            return parse(text)
        }
        return nil
    }

    // MARK: Decision

    public struct Refusal: Error, Sendable, Identifiable {
        public let why: String
        /// Text a person may approve ("" = the field is gone); nil — there is nothing to approve.
        public let ask: String?
        /// Approved before, and what the field was when the task was queued.
        public let approved: String?
        public let queued: String?
        public init(_ why: String, ask: String? = nil, approved: String? = nil, queued: String? = nil) {
            self.why = why; self.ask = ask; self.approved = approved; self.queued = queued
        }
        public var id: String { why + "\n" + (ask ?? "-") }
    }

    public enum Decision: Sendable {
        case none
        case run(String)
        case refuse(Refusal)

        /// "" — nothing to run.
        public var command: String { if case .run(let c) = self { c } else { "" } }
        public var refusal: Refusal? { if case .refuse(let r) = self { r } else { nil } }
    }

    /// `now` — the field as read, nil: no file. `queued` — its text when the task was queued, nil: not known.
    public static func decide(_ now: TaskVerify?, queued: String?, approved: String?) -> Decision {
        let expected = approved ?? queued ?? ""
        switch now {
        case nil:
            return expected.isEmpty ? .none : .refuse(.init("файл задачи не найден"))
        case .invalid(let why, _):
            return .refuse(.init("поле verify задачи: " + why))
        case .some(.none):
            return expected.isEmpty ? .none
                : .refuse(.init("поле verify убрано из задачи — подтверди", ask: "", approved: approved, queued: queued))
        case .command(let c):
            if let approved, same(approved, c) { return .run(c) }
            return .refuse(.init(approved == nil ? "команда не подтверждена" : "команда изменилась после подтверждения",
                                 ask: c, approved: approved, queued: queued))
        }
    }
}

/// Commands of tasks a person approved: exact text per task file. "" — the removal of the field.
/// Kept outside of the project and of queue.json.
public struct TaskVerifyApprovals: Codable, Equatable, Sendable {
    public var byTask: [String: String] = [:]
    public init() {}

    static func key(_ project: URL, _ file: String) -> String { TaskRepos.canonical(project) + "\n" + file }

    public func approved(_ project: URL, _ file: String) -> String? { byTask[Self.key(project, file)] }
    public mutating func approve(_ command: String, _ project: URL, _ file: String) { byTask[Self.key(project, file)] = command }
}
