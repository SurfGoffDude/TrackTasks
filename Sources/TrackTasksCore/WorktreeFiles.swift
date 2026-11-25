import Foundation

/// Extra files of a project's worktrees: `.worktreeinclude` (gitignore-style patterns, files are copied) and
/// `shared:` in about.md (paths, symlinked to the main folder). Only what git ignores, what exists and lies inside the project.
/// What was put into a worktree is written to its git dir, so commit, diff, checkpoints, merge and PR see the same set.
public enum WorktreeFiles {
    /// Always linked when present and ignored (the rule before the settings existed).
    public static let builtin = ["node_modules", ".venv", "venv", "vendor", "Pods", ".env", ".env.local", ".env.development"]
    public static let includeFile = ".worktreeinclude"
    public static let manifestName = "tracktasks-files.json"

    public typealias Git = (_ args: [String], _ dir: URL) -> (ok: Bool, out: String)

    /// What a worktree got from the settings (builtin links are not listed).
    public struct Manifest: Codable, Equatable, Sendable {
        public var copies: [String]
        public var shares: [String]
        public var warnings: [String]
        public init(copies: [String] = [], shares: [String] = [], warnings: [String] = []) {
            self.copies = copies; self.shares = shares; self.warnings = warnings
        }
    }

    // MARK: - Reading the settings

    /// Pattern lines of `.worktreeinclude` (comments and blanks dropped).
    public static func includePatterns(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public static func sharedPaths(projectAt url: URL) -> [String] {
        guard let text = try? String(contentsOf: url.appendingPathComponent("about.md"), encoding: .utf8) else { return [] }
        return Frontmatter.list(Frontmatter.parse(text).fields["shared"]).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Why a path from the settings can't be used, by its text alone. nil — acceptable.
    public static func syntaxProblem(_ raw: String) -> String? {
        let p = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        if p.isEmpty { return "пустой путь" }
        if p.hasPrefix("/") || p.hasPrefix("~") || p.contains("\\") || p.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil {
            return "абсолютный путь"
        }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains("..") { return "«..» в пути" }
        if parts.contains(where: { $0.isEmpty }) { return "пустая часть пути" }
        if parts.contains(where: { $0.lowercased() == ".git" }) { return "путь внутри .git" }
        if p == "." { return "вся папка проекта" }
        if p.contains("\n") || p.contains("\0") { return "недопустимые символы" }
        return nil
    }

    // MARK: - Checks against the disk and git

    /// Why `path` (relative to the project) can't be copied or linked. nil — acceptable.
    public static func problem(_ path: String, project: URL, git: Git, forCopy: Bool) -> String? {
        let p = path.hasSuffix("/") ? String(path.dropLast()) : path
        if let why = syntaxProblem(p) { return why }
        let fm = FileManager.default
        let src = project.appendingPathComponent(p)
        guard (try? fm.attributesOfItem(atPath: src.path)) != nil else { return "нет такого файла" }
        let root = project.resolvingSymlinksInPath().path
        let real = src.resolvingSymlinksInPath().path
        guard real.hasPrefix(root + "/") else { return "ссылка за пределы проекта" }
        if forCopy, (try? fm.destinationOfSymbolicLink(atPath: src.path)) != nil { return "это символическая ссылка" }
        if forCopy, let bad = outwardLink(in: src, root: root) { return "внутри ссылка наружу: \(bad)" }
        let tracked = git(["ls-files", "-z", "--", p], project)
        if !tracked.ok { return "git не ответил" }
        if !tracked.out.isEmpty { return "отслеживается git" }
        if !git(["check-ignore", "-q", "--", p], project).ok { return "не игнорируется git" }
        return nil
    }

    private static func outwardLink(in dir: URL, root: String) -> String? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return nil }
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
            let real = u.resolvingSymlinksInPath().path
            if !real.hasPrefix(root + "/") { return u.lastPathComponent }
        }
        return nil
    }

    // MARK: - Plan

    public struct Plan: Equatable, Sendable {
        public var copies: [String] = []
        public var shares: [String] = []
        public var warnings: [String] = []
        public var isEmpty: Bool { copies.isEmpty && shares.isEmpty && warnings.isEmpty }
    }

    /// What to put into a new worktree of `project` (reads `.worktreeinclude` and about.md). Without them — an empty plan.
    public static func plan(project: URL, git: Git) -> Plan {
        var plan = Plan()
        var taken = Set(builtin)
        // shared: explicit paths.
        for raw in sharedPaths(projectAt: project) {
            let p = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if taken.contains(p) { continue }
            if let why = problem(p, project: project, git: git, forCopy: false) {
                plan.warnings.append("shared: «\(raw)» пропущен — \(why)")
                continue
            }
            taken.insert(p)
            plan.shares.append(p)
        }
        // .worktreeinclude: patterns.
        guard let text = try? String(contentsOf: project.appendingPathComponent(includeFile), encoding: .utf8) else { return plan }
        var patterns: [String] = []
        for line in includePatterns(text) {
            if line.hasPrefix("!") { plan.warnings.append("\(includeFile): «\(line)» пропущен — отрицание не поддерживается"); continue }
            // An anchoring slash is gitignore syntax; a real absolute path (it exists) is refused.
            if line.hasPrefix("/"), FileManager.default.fileExists(atPath: line), !line.hasPrefix(project.path + "/") {
                plan.warnings.append("\(includeFile): «\(line)» пропущен — абсолютный путь"); continue
            }
            let body = line.hasPrefix("/") ? String(line.dropFirst()) : line
            if let why = syntaxProblem(body.replacingOccurrences(of: "**/", with: "").replacingOccurrences(of: "/**", with: "")) {
                plan.warnings.append("\(includeFile): «\(line)» пропущен — \(why)"); continue
            }
            patterns.append(line)
            if !body.contains(where: { "*?[".contains($0) }) {
                // A plain path: say why it gives nothing.
                if let why = problem(body, project: project, git: git, forCopy: true) {
                    plan.warnings.append("\(includeFile): «\(line)» пропущен — \(why)")
                    patterns.removeLast()
                }
            }
        }
        guard !patterns.isEmpty else { return plan }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tracktasks-include-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? (patterns.joined(separator: "\n") + "\n").write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return plan }
        let found = git(["ls-files", "-z", "--others", "--ignored", "--directory", "--exclude-from=\(tmp.path)"], project)
        guard found.ok else { plan.warnings.append("\(includeFile): git не смог разобрать шаблоны"); return plan }
        var chosen: [String] = []
        for item in found.out.split(separator: "\0").map(String.init).sorted() {
            let p = item.hasSuffix("/") ? String(item.dropLast()) : item
            if taken.contains(p) || chosen.contains(where: { p.hasPrefix($0 + "/") }) { continue }
            // Under a builtin or shared link the file already shows up there.
            if taken.contains(where: { p.hasPrefix($0 + "/") }) { continue }
            if let why = problem(p, project: project, git: git, forCopy: true) {
                plan.warnings.append("\(includeFile): «\(p)» пропущен — \(why)")
                continue
            }
            chosen.append(p)
        }
        plan.copies = chosen
        return plan
    }

    // MARK: - Applying

    /// Copies and links per `plan` into `worktree`. Returns the manifest (with warnings of this step added).
    public static func apply(_ plan: Plan, from project: URL, to worktree: URL) -> Manifest {
        var m = Manifest(warnings: plan.warnings)
        let fm = FileManager.default
        let wtRoot = worktree.resolvingSymlinksInPath().path
        func prepare(_ p: String) -> URL? {
            let dst = worktree.appendingPathComponent(p)
            if (try? fm.attributesOfItem(atPath: dst.path)) != nil { m.warnings.append("«\(p)» уже есть в worktree — не тронут"); return nil }
            let parent = dst.deletingLastPathComponent()
            do { try fm.createDirectory(at: parent, withIntermediateDirectories: true) } catch {
                m.warnings.append("«\(p)»: \(error.localizedDescription)"); return nil
            }
            guard parent.resolvingSymlinksInPath().path.hasPrefix(wtRoot) else {
                m.warnings.append("«\(p)» пропущен — папка ведёт за пределы worktree"); return nil
            }
            return dst
        }
        for p in plan.shares {
            guard let dst = prepare(p) else { continue }
            do { try fm.createSymbolicLink(at: dst, withDestinationURL: project.appendingPathComponent(p)); m.shares.append(p) }
            catch { m.warnings.append("shared: «\(p)»: \(error.localizedDescription)") }
        }
        for p in plan.copies {
            guard let dst = prepare(p) else { continue }
            do { try fm.copyItem(at: project.appendingPathComponent(p), to: dst); m.copies.append(p) }
            catch { m.warnings.append("копия «\(p)»: \(error.localizedDescription)") }
        }
        return m
    }

    // MARK: - Manifest

    /// Git dir of a linked worktree (`.git` is a file «gitdir: …»).
    public static func gitDir(of worktree: URL) -> URL? {
        guard let s = try? String(contentsOf: worktree.appendingPathComponent(".git"), encoding: .utf8), s.hasPrefix("gitdir:") else { return nil }
        let path = s.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    public static func write(_ m: Manifest, to worktree: URL) {
        guard let dir = gitDir(of: worktree), let data = try? JSONEncoder().encode(m) else { return }
        try? data.write(to: dir.appendingPathComponent(manifestName))
    }

    /// nil — an old worktree (or a container one): only the builtin set.
    public static func manifest(of worktree: URL) -> Manifest? {
        guard let dir = gitDir(of: worktree), let data = try? Data(contentsOf: dir.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Names git must not commit, diff or snapshot in this worktree: builtin links, shared links and copies.
    public static func links(of worktree: URL) -> [String] {
        guard let m = manifest(of: worktree) else { return builtin }
        return builtin + m.shares + m.copies
    }
}
