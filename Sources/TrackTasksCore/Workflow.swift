import Foundation

/// Pipeline of a task: `workflows/<name>.md` in the project. Steps are `## Title` sections that start with `- key: value`
/// lines; the rest of a section is added to the step's prompt. There is no merge step: merging is the person's.
public struct Workflow: Codable, Hashable, Sendable {
    public enum StepType: String, Codable, CaseIterable, Sendable {
        case plan, code, review, fix

        public var title: String {
            switch self {
            case .plan: "План"
            case .code: "Код"
            case .review: "Ревью"
            case .fix: "Исправление"
            }
        }
    }

    public enum Stop: String, Codable, CaseIterable, Sendable { case none, before, after }

    public struct Step: Codable, Hashable, Sendable {
        public var title: String
        public var type: StepType
        /// Agent profile, "" = the task's one.
        public var agent = ""
        /// Overrides the model of the profile.
        public var model = ""
        /// nil = not written: `after` for a plan, `none` for the rest.
        public var stop: Stop?
        /// Title of a step or `end`; "" = the next section.
        public var next = ""
        /// Review only: where remarks lead, "" = the person decides.
        public var onIssues = ""
        /// How many times the step may be started, nil = not limited by itself.
        public var repeats: Int?
        /// Added to the prompt.
        public var text = ""
        /// `- key: value` lines this version doesn't know, kept as they were.
        public var unknown: [String] = []

        public init(title: String, type: StepType) {
            self.title = title
            self.type = type
        }

        public var stops: Stop { stop ?? (type == .plan ? .after : .none) }
    }

    public struct Problem: Hashable, Sendable {
        public var isError: Bool
        public var message: String
        public init(error: String) { isError = true; message = error }
        public init(warning: String) { isError = false; message = warning }
    }

    public var title = ""
    /// USD for the whole task, nil = no limit.
    public var budget: Double?
    public var steps: [Step] = []

    public init(title: String = "", budget: Double? = nil, steps: [Step] = []) {
        self.title = title
        self.budget = budget
        self.steps = steps
    }

    public static let folder = "workflows"
    public static let end = "end"
    public static let repeatsRange = 1...10

    public enum Target: Codable, Hashable, Sendable {
        case step(Int)
        case end
    }

    static func key(_ title: String) -> String { title.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Written transition; nil = no such step.
    func target(named name: String) -> Target? {
        let k = Self.key(name)
        if k == Self.end { return .end }
        return steps.firstIndex { Self.key($0.title) == k }.map(Target.step)
    }

    /// Where the step leads when it succeeded (a review: «ОК»); nil = a wrong name.
    public func next(after i: Int) -> Target? {
        guard steps.indices.contains(i) else { return nil }
        if !steps[i].next.isEmpty { return target(named: steps[i].next) }
        return i + 1 < steps.count ? .step(i + 1) : .end
    }

    /// Where remarks of a review lead; nil = the person decides.
    public func onIssues(_ i: Int) -> Target? {
        guard steps.indices.contains(i), !steps[i].onIssues.isEmpty else { return nil }
        return target(named: steps[i].onIssues)
    }

    // MARK: Parsing

    private struct Section {
        var title: String
        var lines: [String] = []
    }

    /// Body before the first `## ` and the sections. Headings inside code fences don't count.
    private static func split(_ body: String) -> (preamble: String, sections: [Section]) {
        var preamble: [String] = [], sections: [Section] = [], fence = false
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fence.toggle() }
            if !fence, line.hasPrefix("## ") {
                sections.append(Section(title: line.dropFirst(3).trimmingCharacters(in: .whitespaces)))
            } else if sections.isEmpty {
                preamble.append(line)
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }
        return (preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), sections)
    }

    /// The `- key: value` lines a section starts with and the text after them.
    private static func fields(_ s: Section) -> (fields: [(key: String, value: String, line: String)], text: String) {
        var out: [(key: String, value: String, line: String)] = [], rest = s.lines[...]
        while rest.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { rest.removeFirst() }
        while let line = rest.first, let m = line.wholeMatch(of: #/\s*-\s+([A-Za-z][A-Za-z_]*)\s*:\s*(.*?)\s*/#) {
            out.append((m.1.lowercased(), Frontmatter.unquote(String(m.2)), line))
            rest.removeFirst()
        }
        return (out, rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// nil = not a pipeline: no section names a step `type`. Values that can't be read are errors.
    public static func parse(_ raw: String) -> (workflow: Workflow, problems: [Problem])? {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let (f, body) = Frontmatter.parse(text)
        let parts = split(body).sections.map { ($0.title, fields($0)) }
        guard parts.contains(where: { $0.1.fields.contains { $0.key == "type" } }) else { return nil }
        var w = Workflow(title: Frontmatter.stripComment(f["title"] ?? "")), problems: [Problem] = []
        if let v = f["budget"].map(Frontmatter.stripComment), !v.isEmpty {
            if let n = Double(v), n.isFinite, n > 0 { w.budget = n }
            else { problems.append(.init(error: "budget: \(v) — нужно число больше нуля (USD)")) }
        }
        for (title, part) in parts {
            let name = title.isEmpty ? "без названия" : title
            func bad(_ m: String) { problems.append(.init(error: "Шаг «\(name)»: \(m)")) }
            var s = Step(title: title, type: .code), hasType = false, seen = Set<String>()
            s.text = part.text
            for f in part.fields {
                if !seen.insert(f.key).inserted { bad("поле \(f.key) указано дважды") }
                switch f.key {
                case "type":
                    hasType = true
                    if let t = StepType(rawValue: f.value.lowercased()) { s.type = t }
                    else if f.value.lowercased() == "merge" { bad("шага merge нет: сливает всегда человек") }
                    else { bad("type: \(f.value) — допустимо plan | code | review | fix") }
                case "agent":
                    s.agent = f.value.lowercased()
                    if !s.agent.isEmpty, !AgentProfile.isValidID(s.agent) { bad("agent: \(f.value) — нужно имя профиля, например claude") }
                case "model": s.model = f.value
                case "stop":
                    s.stop = Stop(rawValue: f.value.lowercased())
                    if s.stop == nil { bad("stop: \(f.value) — допустимо before | after | none") }
                case "next": s.next = f.value
                case "on_issues": s.onIssues = f.value
                case "repeats":
                    if let n = Int(f.value), repeatsRange.contains(n) { s.repeats = n }
                    else { bad("repeats: \(f.value) — нужно число от 1 до 10") }
                default:
                    s.unknown.append(f.line.trimmingCharacters(in: .whitespaces))
                    problems.append(.init(warning: "Шаг «\(name)»: неизвестное поле \(f.key)"))
                }
            }
            if !hasType { bad("нет type (plan | code | review | fix)") }
            w.steps.append(s)
        }
        return (w, problems)
    }

    /// File text. `original`: its unknown frontmatter fields and the text before the steps stay.
    public func serialized(updating original: String = "") -> String {
        let old = original.replacingOccurrences(of: "\r\n", with: "\n")
        var head = Frontmatter.setting("title", to: Frontmatter.quote(title), in: old.hasPrefix("---") ? old : "---\n---\n")
        head = Frontmatter.setting("budget", to: budget.map { $0 == $0.rounded() && abs($0) < 1e9 ? String(Int($0)) : String($0) } ?? "", in: head)
        let lines = head.components(separatedBy: "\n")
        let close = lines.indices.dropFirst().first { lines[$0].trimmingCharacters(in: .whitespaces) == "---" } ?? 0
        var out = lines[...close].joined(separator: "\n") + "\n"
        let preamble = Self.split(Frontmatter.parse(old).body).preamble
        if !preamble.isEmpty { out += "\n\(preamble)\n" }
        for s in steps {
            out += "\n## \(s.title)\n- type: \(s.type.rawValue)\n"
            if !s.agent.isEmpty { out += "- agent: \(s.agent)\n" }
            if !s.model.isEmpty { out += "- model: \(s.model)\n" }
            if let v = s.stop { out += "- stop: \(v.rawValue)\n" }
            if !s.next.isEmpty { out += "- next: \(s.next)\n" }
            if !s.onIssues.isEmpty { out += "- on_issues: \(s.onIssues)\n" }
            if let n = s.repeats { out += "- repeats: \(n)\n" }
            for u in s.unknown { out += u + "\n" }
            if !s.text.isEmpty { out += "\n\(s.text)\n" }
        }
        return out
    }

    // MARK: Linter

    /// Errors make the file unusable: it can't be started or imported.
    public func lint() -> [Problem] {
        var out: [Problem] = []
        func bad(_ m: String) { out.append(.init(error: m)) }
        if !steps.contains(where: { $0.type == .code }) { bad("Нет шага code") }
        if steps.filter({ $0.type == .code }).count > 1 { bad("Шаг code может быть только один: дальше — review и fix") }
        if let f = steps.first, f.type != .plan, f.type != .code {
            bad("Первый шаг — plan или code" + (f.type == .fix ? ": fix без предшествующего review" : ""))
        }
        var titles = Set<String>()
        for s in steps {
            let k = Self.key(s.title)
            if k.isEmpty { bad("Шаг без названия") }
            else if k == Self.end { bad("Название «\(Self.end)» занято: так пишется конец пайплайна") }
            else if !titles.insert(k).inserted { bad("Дубль названия шага: «\(s.title)»") }
            if let n = s.repeats, !Self.repeatsRange.contains(n) { bad("Шаг «\(s.title)»: repeats — от 1 до 10") }
        }
        if let b = budget, !(b.isFinite && b > 0) { bad("budget — число больше нуля") }
        var edges = [[Int]](repeating: [], count: steps.count)
        for (i, s) in steps.enumerated() {
            func edge(_ t: Target?, _ field: String, _ name: String) {
                guard let t else { return bad("Шаг «\(s.title)»: \(field): нет шага «\(name)»") }
                guard case .step(let j) = t else { return }
                edges[i].append(j)
                let to = steps[j]
                let allowed: [StepType] = switch s.type {
                case .plan: [.plan, .code]
                case .code: [.review]
                case .review, .fix: [.review, .fix]
                }
                if !allowed.contains(to.type) {
                    bad("«\(s.title)» → «\(to.title)»: после \(s.type.rawValue) не может идти \(to.type.rawValue)"
                        + (to.type == .fix ? " (fix без предшествующего review)" : ""))
                } else if s.type == .review, field == "next", to.type == .fix {
                    bad("«\(s.title)»: вердикт «ОК» ведёт в исправление «\(to.title)» — укажи next: \(Self.end)")
                }
            }
            edge(next(after: i), "next", s.next)
            if !s.onIssues.isEmpty {
                if s.type != .review { bad("Шаг «\(s.title)»: on_issues бывает только у review") }
                else if target(named: s.onIssues) == .end { bad("Шаг «\(s.title)»: on_issues не может быть \(Self.end) — с замечаниями пайплайн не заканчивается") }
                else { edge(target(named: s.onIssues), "on_issues", s.onIssues) }
            }
            // A plan that leads to the end never writes code.
            if s.type == .plan, next(after: i) == .end { bad("«\(s.title)»: после плана нужен шаг code") }
        }
        var reached = Set<Int>(), stack = steps.isEmpty ? [] : [0]
        while let i = stack.popLast() { if reached.insert(i).inserted { stack += edges[i] } }
        for i in steps.indices where !reached.contains(i) { bad("Шаг «\(steps[i].title)» недостижим") }
        if let c = unlimitedCycle(edges) {
            bad("Цикл без лимита: \(c.map { "«\(steps[$0].title)»" }.joined(separator: " → ")) — укажи repeats хотя бы у одного шага")
        }
        return out
    }

    /// Steps with `repeats` can't go on forever; what is left must have no cycles.
    private func unlimitedCycle(_ edges: [[Int]]) -> [Int]? {
        var left = Set(steps.indices.filter { steps[$0].repeats == nil })
        while let i = left.sorted().first(where: { i in !edges[i].contains { left.contains($0) } }) { left.remove(i) }
        // Every remaining step leads to a remaining one: walk until a repeat.
        guard var i = left.min() else { return nil }
        var path: [Int] = []
        while !path.contains(i) {
            path.append(i)
            guard let n = edges[i].first(where: { left.contains($0) }) else { return nil }
            i = n
        }
        return Array(path[path.firstIndex(of: i)!...]) + [i]
    }

    /// What depends on this machine: profiles and what their agents report.
    /// `cost`: nil = no such profile ("" = the default one), else whether its agent reports the cost.
    public func warnings(taskAgent: String = "", cost: (String) -> Bool?) -> [Problem] {
        var out: [Problem] = []
        for s in steps {
            let profile = s.agent.isEmpty ? taskAgent : s.agent
            switch cost(profile) {
            case nil: out.append(.init(warning: "Шаг «\(s.title)»: на этой машине нет профиля «\(profile)»"))
            case false? where budget != nil:
                out.append(.init(warning: "Шаг «\(s.title)»: его агент не сообщает стоимость — budget её не учтёт"))
            default: break
            }
        }
        return out
    }

    public static var template: Workflow {
        var plan = Step(title: "План", type: .plan)
        plan.stop = .after
        var review = Step(title: "Ревью", type: .review)
        review.next = end
        review.onIssues = "Исправление"
        var fix = Step(title: "Исправление", type: .fix)
        fix.next = "Ревью"
        fix.repeats = 2
        return Workflow(title: "План → Код → Ревью → Исправление", steps: [plan, Step(title: "Код", type: .code), review, fix])
    }
}

/// `workflows/<name>.md` as it is on disk.
public struct WorkflowFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public var text: String
    public var workflow: Workflow
    /// Parser and linter; warnings about profiles are added by the app.
    public var problems: [Workflow.Problem]

    public var id: String { url.path }
    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var errors: [String] { problems.filter(\.isError).map(\.message) }

    public static let maxBytes = 200_000

    /// nil = not a pipeline.
    public init?(url: URL, text: String) {
        guard let p = Workflow.parse(text) else { return nil }
        self.url = url
        self.text = text
        workflow = p.workflow
        problems = p.problems + p.workflow.lint()
        if !AgentProfile.isValidID(name) {
            problems.append(.init(error: "Имя файла «\(name)»: строчные латинские буквы, цифры, «.», «_», «-»"))
        }
    }

    public static func url(_ name: String, in project: URL) -> URL {
        project.appendingPathComponent(Workflow.folder, isDirectory: true).appendingPathComponent(name + ".md")
    }

    /// Why the file can't be used, or the file.
    public static func load(_ url: URL) -> Result<WorkflowFile, LoadError> {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        guard let size else { return .failure(.init("нет файла \(url.lastPathComponent)")) }
        guard size <= maxBytes else { return .failure(.init("файл больше \(maxBytes / 1000) КБ")) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .failure(.init("файл не читается")) }
        guard let f = WorkflowFile(url: url, text: text) else { return .failure(.init("в файле нет шагов (разделы «## …» с «- type:»)")) }
        return .success(f)
    }

    public struct LoadError: Error, Equatable {
        public let message: String
        init(_ m: String) { message = m }
    }

    /// Only `.md` files right in `workflows/`; files without steps are the project's own.
    public static func all(in project: URL) -> [WorkflowFile] {
        let dir = project.appendingPathComponent(Workflow.folder, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? load($0).get() }
    }
}
