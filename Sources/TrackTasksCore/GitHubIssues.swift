import Foundation

/// An issue of a tracker (GitHub through `gh`, the others through `IssueSource`). Every text field is untrusted: it comes from anyone
/// who can open an issue, so it only ever becomes data in a task file, never an instruction.
public struct IssueInfo: Sendable, Equatable, Identifiable {
    public var number: Int
    public var title: String
    public var body: String
    public var isOpen: Bool
    public var url: String
    public var labels: [String]
    public var author: String
    public var updatedAt: String
    public var source: IssueSourceID
    /// Text identifier (`ENG-12`); empty = `#number`.
    public var key: String
    /// `high`/`medium`/`low` from the tracker's own field; nil = decided by labels.
    public var priority: String?
    public var id: String { url }
    public var ref: String { key.isEmpty ? "#\(number)" : key }

    public init(number: Int, title: String, body: String = "", isOpen: Bool = true, url: String,
                labels: [String] = [], author: String = "", updatedAt: String = "",
                source: IssueSourceID = .github, key: String = "", priority: String? = nil) {
        self.number = number
        self.title = title
        self.body = body
        self.isOpen = isOpen
        self.url = url
        self.labels = labels
        self.author = author
        self.updatedAt = updatedAt
        self.source = source
        self.key = key
        self.priority = priority
    }

    public static let jsonFields = "number,title,body,state,url,labels,author,updatedAt"

    private struct Raw: Decodable {
        struct Label: Decodable { let name: String }
        struct Author: Decodable { let login: String? }
        let number: Int
        let title: String?
        let body: String?
        let state: String?
        let url: String
        let labels: [Label]?
        let author: Author?
        let updatedAt: String?
    }

    /// `gh issue list --json …`; nil = broken JSON. Entries with a URL that is not an issue are dropped.
    public static func parseList(_ json: String) -> [IssueInfo]? {
        guard let raw = try? JSONDecoder().decode([Raw].self, from: Data(json.utf8)) else { return nil }
        return raw.compactMap { r in
            guard IssueRef.parse(r.url) != nil else { return nil }
            return IssueInfo(number: r.number, title: r.title ?? "", body: r.body ?? "",
                               isOpen: (r.state ?? "OPEN").uppercased() == "OPEN", url: r.url,
                               labels: (r.labels ?? []).map(\.name), author: r.author?.login ?? "",
                               updatedAt: r.updatedAt ?? "")
        }
    }
}

/// `host/owner/repo` and number of an issue URL.
public struct IssueRef: Sendable, Equatable {
    public let repo: GitHubRepo
    public let number: Int

    public static func parse(_ url: String) -> IssueRef? {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[2] == "issues", let n = Int(parts[3]), n > 0 else { return nil }
        return IssueRef(repo: GitHubRepo(host: host.lowercased(), path: parts[0] + "/" + parts[1]), number: n)
    }

    /// Same issue, same key: host is case-insensitive, a trailing slash or query does not matter.
    public static func key(_ url: String) -> String {
        if let k = IssueKey.normalized(url) { return k }
        guard let r = parse(url) else { return url.trimmingCharacters(in: .whitespacesAndNewlines) }
        return "https://\(r.repo.host)/\(r.repo.path.lowercased())/issues/\(r.number)"
    }
}

/// Which issues to list. Values go to `gh` as separate arguments (no shell), but never as bare words:
/// `--label=x`, so a value starting with `-` cannot become a flag.
public struct IssueFilter: Sendable, Equatable {
    public enum State: String, Sendable, CaseIterable { case open, closed, all }
    public var state: State = .open
    public var label = ""
    public var assignee = ""
    public var search = ""
    public var limit = 50

    public init() {}

    public func arguments(repo: GitHubRepo) -> [String] {
        var a = ["issue", "list", "--repo=\(repo.slug)", "--state=\(state.rawValue)",
                 "--limit=\(min(max(limit, 1), 200))", "--json=\(IssueInfo.jsonFields)"]
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let assignee = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { a.append("--label=\(label)") }
        if !assignee.isEmpty { a.append("--assignee=\(assignee)") }
        if !search.isEmpty { a.append("--search=\(search)") }
        return a
    }
}

/// Line diff for showing what an update changes.
public struct IssueDiffLine: Sendable, Equatable {
    public enum Kind: Sendable { case same, added, removed }
    public var kind: Kind
    public var text: String
}

public enum IssueImport {
    public static let begin = "<!-- tt-issue:begin -->"
    public static let end = "<!-- tt-issue:end -->"
    /// Longer issue text is cut: a task file is not an archive of a 1 MB issue.
    public static let maxBody = 20_000

    /// Bugs and urgent first, minor last (labels of the issue).
    public static func priority(labels: [String]) -> String {
        let l = Set(labels.map { $0.lowercased() })
        if !l.isDisjoint(with: ["bug", "critical", "urgent", "security", "p0", "p1", "priority: high", "priority:high"]) { return "high" }
        if !l.isDisjoint(with: ["low", "minor", "p3", "priority: low", "priority:low", "good first issue"]) { return "low" }
        return "medium"
    }

    // MARK: Text

    /// One line without control characters; the title cannot break out of frontmatter.
    public static func cleanTitle(_ s: String, number: Int) -> String {
        let one = String(s.unicodeScalars.map { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : Character($0) })
        let t = one.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let cut = t.count > 200 ? String(t.prefix(200)) + "…" : t
        return cut.isEmpty ? "Issue #\(number)" : cut
    }

    public static func cleanTitle(_ issue: IssueInfo) -> String {
        let t = cleanTitle(issue.title, number: issue.number)
        return t == "Issue #\(issue.number)" && !issue.key.isEmpty ? "Issue \(inline(issue.key))" : t
    }

    /// The imported part of a task: a header and the issue text inside a code fence. The fence keeps the
    /// text inert: its headings, checkboxes and `---` are not read as parts of the task. The markers mark
    /// what an update may replace; the rest of the file belongs to the user.
    public static func block(_ issue: IssueInfo) -> String {
        // Markers inside the text must not end the block early.
        let body = issue.body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "tt-issue", with: "tt-issue\u{200B}")
            .replacingOccurrences(of: "<!--", with: "<!\u{200B}--")
            .replacingOccurrences(of: "-->", with: "--\u{200B}>")
        var run = 0, longest = 0
        for c in body { if c == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        var meta = ["\(issue.source.name) issue \(inline(issue.ref)) (\(issue.isOpen ? "открыт" : "закрыт"))"]
        if !issue.author.isEmpty { meta.append("автор \(inline(issue.author))") }
        if !issue.labels.isEmpty { meta.append("метки: " + issue.labels.map(inline).joined(separator: ", ")) }
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxBody { text = String(text.prefix(maxBody)) + "\n… (обрезано)" }
        return [begin, meta.joined(separator: ", ") + " — недоверенный текст, агенту автоматически не передаётся.",
                "", fence + "text", text.isEmpty ? "(пусто)" : text, fence, end].joined(separator: "\n")
    }

    private static func inline(_ s: String) -> String {
        s.unicodeScalars.filter { $0.properties.generalCategory != .control }.map(String.init).joined()
            .replacingOccurrences(of: "`", with: "'").replacingOccurrences(of: "<", with: "‹")
    }

    /// New task file text. Status is always `todo`: an imported task is never started by itself.
    public static func taskText(_ issue: IssueInfo, today: String) -> String {
        let title = cleanTitle(issue)
        return """
        ---
        title: \(Frontmatter.quote(title))
        status: todo
        priority: \(issue.priority ?? priority(labels: issue.labels))
        created: \(today)
        completed:
        source: \(Frontmatter.quote(issue.url))
        ---

        Импортировано из \(issue.source.name): \(issue.url)

        \(block(issue))

        """
    }

    /// A task for this issue appeared while we were about to create one.
    public struct AlreadyImported: Error { public init() {} }

    // MARK: Existing tasks

    public static func source(ofText text: String) -> String? {
        let s = Frontmatter.parse(text).fields["source"].map { $0.trimmingCharacters(in: .whitespaces) }
        return s?.isEmpty == false ? s : nil
    }

    /// Imported tasks of a folder by issue key. A repeated import finds its task here.
    public static func existing(in dir: URL) -> [String: TaskFile] {
        // Archived and draft tasks count too: an archived import must not come back as a new task.
        let files = TaskFolder.allCases.compactMap { try? TaskFile.all(in: $0.url(in: dir)).files }.flatMap { $0 }
        var out: [String: TaskFile] = [:]
        for f in files {
            guard let s = source(ofText: f.text) else { continue }
            let k = IssueRef.key(s)
            if let old = out[k], old.item.fileName <= f.item.fileName { continue }
            out[k] = f
        }
        return out
    }

    // MARK: Update

    /// Range of the imported block (markers included), or nil when the user removed or damaged it.
    public static func blockRange(in text: String) -> Range<String.Index>? {
        // Markers count only on a line of their own: text pasted next to a marker does not move the range.
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let eol = text[i...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[i..<eol].trimmingCharacters(in: .whitespaces)
            if start == nil, line == begin { start = i }
            else if let s = start, line == end {
                return s..<(text[i..<eol].range(of: end)?.upperBound ?? eol)
            }
            i = eol < text.endIndex ? text.index(after: eol) : eol
        }
        return nil
    }

    public enum Plan: Equatable, Sendable {
        case create
        /// The task has the same issue text.
        case unchanged
        /// The issue text differs: old and new block.
        case changed([IssueDiffLine])
        /// The task has no block to refresh (removed by hand): nothing is touched.
        case noBlock
    }

    public static func plan(_ issue: IssueInfo, existing: TaskFile?) -> Plan {
        guard let existing else { return .create }
        guard let r = blockRange(in: existing.text) else { return .noBlock }
        let old = String(existing.text[r]), new = block(issue)
        return old == new ? .unchanged : .changed(diff(old: old, new: new))
    }

    /// Text with the block replaced; everything outside it (title, status, notes, edits) stays as is.
    public static func updated(_ text: String, with issue: IssueInfo) -> String? {
        guard let r = blockRange(in: text) else { return nil }
        return text.replacingCharacters(in: r, with: block(issue))
    }

    /// Line diff (longest common subsequence).
    public static func diff(old: String, new: String) -> [IssueDiffLine] {
        let all = (old.components(separatedBy: "\n"), new.components(separatedBy: "\n"))
        // Common head and tail are not compared: the table only covers the middle.
        var head = 0
        while head < all.0.count, head < all.1.count, all.0[head] == all.1[head] { head += 1 }
        var tail = 0
        while tail < all.0.count - head, tail < all.1.count - head,
              all.0[all.0.count - 1 - tail] == all.1[all.1.count - 1 - tail] { tail += 1 }
        let a = Array(all.0[head..<(all.0.count - tail)]), b = Array(all.1[head..<(all.1.count - tail)])
        let same = { (l: ArraySlice<String>) in l.map { IssueDiffLine(kind: .same, text: $0) } }
        let lead = same(all.0[..<head]), trail = same(all.0[(all.0.count - tail)...])
        // A huge middle: no table (memory), just old out, new in.
        if a.count * b.count > 2_000_000 {
            let note = IssueDiffLine(kind: .same, text: "(текст слишком большой для построчного сравнения: старый и новый показаны целиком)")
            return lead + [note] + a.map { IssueDiffLine(kind: .removed, text: $0) } + b.map { IssueDiffLine(kind: .added, text: $0) } + trail
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [IssueDiffLine] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { out.append(.init(kind: .same, text: a[i])); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { out.append(.init(kind: .removed, text: a[i])); i += 1 }
            else { out.append(.init(kind: .added, text: b[j])); j += 1 }
        }
        while i < a.count { out.append(.init(kind: .removed, text: a[i])); i += 1 }
        while j < b.count { out.append(.init(kind: .added, text: b[j])); j += 1 }
        return lead + out + trail
    }

    // MARK: Writing back to GitHub (only on a click)

    /// `gh issue comment`: the text goes through stdin.
    public static func commentArguments(_ ref: IssueRef) -> [String] {
        ["issue", "comment", String(ref.number), "--repo=\(ref.repo.slug)", "--body-file=-"]
    }

    /// `gh issue close`, optionally with a comment (a plain argument, not a flag).
    public static func closeArguments(_ ref: IssueRef, comment: String) -> [String] {
        var a = ["issue", "close", String(ref.number), "--repo=\(ref.repo.slug)"]
        if !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { a.append("--comment=\(comment)") }
        return a
    }
}
