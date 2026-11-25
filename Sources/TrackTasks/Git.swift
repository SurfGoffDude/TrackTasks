import Foundation
import TrackTasksCore

struct GitInfo: Hashable {
    var branch = ""
    var dirty = 0
    var ahead = 0
    var behind = 0
    var hasUpstream = false
    var lastCommit = ""
    var lastCommitTime: Date?
}

/// "When did I last actually touch this project?" — newest file mtime, ignoring tracker files and heavy dirs.
enum Activity {
    static let skipDirs: Set<String> = [
        "node_modules", "vendor", "build", "dist", "target", "DerivedData", "Pods",
        "__pycache__", "venv", "coverage", "bin", "obj",
    ]
    static let maxEntries = 60_000
    /// Full tree walks are reused for this long; FSEvents keep the cached date fresh in between via `note`.
    static let cacheTTL: TimeInterval = 15 * 60

    private static let cacheLock = NSLock()
    private static var cache: [String: (date: Date?, at: Date)] = [:]

    /// `lastModified` with a TTL cache keyed by project path.
    static func cachedLastModified(_ root: URL) -> Date? {
        let key = root.path
        cacheLock.lock()
        if let c = cache[key], Date().timeIntervalSince(c.at) < cacheTTL {
            cacheLock.unlock()
            return c.date
        }
        cacheLock.unlock()
        var d = Log.fs.measure("Activity.lastModified", root.lastPathComponent) { lastModified(root) }
        cacheLock.lock()
        // Keep a newer change noted via FSEvents (e.g. while the walk was running).
        if let noted = cache[key]?.date, noted > (d ?? .distantPast) { d = noted }
        cache[key] = (d, Date())
        cacheLock.unlock()
        return d
    }

    /// A file in the project changed at `date` (seen via FSEvents) — bump the cached value.
    static func note(_ root: URL, at date: Date) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let c = cache[root.path] else { return }
        if date > (c.date ?? .distantPast) { cache[root.path] = (date, c.at) }
    }

    static func lastModified(_ root: URL) -> Date? {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let prefix = root.path.count + 1
        var newest: Date?
        var seen = 0
        for case let url as URL in e {
            seen += 1
            if seen > maxEntries { break }
            let rel = url.path.count > prefix ? String(url.path.dropFirst(prefix)) : ""
            if rel == "tasks" { e.skipDescendants(); continue }
            if rel == "about.md" || SpecDoc.isSpec(rel) { continue }
            guard let v = try? url.resourceValues(forKeys: keys) else { continue }
            if v.isDirectory == true {
                if skipDirs.contains(url.lastPathComponent) { e.skipDescendants() }
                continue
            }
            if let d = v.contentModificationDate, d > (newest ?? .distantPast) { newest = d }
        }
        return newest
    }
}

/// Thin wrapper over /usr/bin/git. All calls are synchronous — run them off the main thread.
enum Git {
    struct Commit {
        let date: String
        let subject: String
    }

    static func isRepo(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    static func run(_ args: [String], in url: URL) -> String? {
        guard ContainerStore.shared.refusal(url) == nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", url.path] + ContainerStore.shared.gitOptions(url) + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        Log.git.process("git", project: url.lastPathComponent, command: args.joined(separator: " "))
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func info(_ url: URL) -> GitInfo? {
        guard isRepo(url),
              let status = run(["status", "--porcelain=v2", "--branch"], in: url) else { return nil }
        var info = GitInfo()
        for line in status.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                info.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                info.hasUpstream = true
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 {
                    info.ahead = Int(parts[0].dropFirst()) ?? 0
                    info.behind = Int(parts[1].dropFirst()) ?? 0
                }
            } else if !line.hasPrefix("#"), let path = entryPath(line), !isTrackerFile(path) {
                info.dirty += 1
            }
        }
        let log = run(["log", "-1", "--format=%cs %ct"], in: url)?
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ") ?? []
        if log.count == 2 {
            info.lastCommit = String(log[0])
            info.lastCommitTime = TimeInterval(log[1]).map(Date.init(timeIntervalSince1970:))
        }
        return info
    }

    /// Path from a `git status --porcelain=v2` entry line.
    private static func entryPath(_ line: Substring) -> String? {
        switch line.first {
        case "?", "!":
            return String(line.dropFirst(2))
        case "1":
            let f = line.split(separator: " ", maxSplits: 8)
            return f.count == 9 ? String(f[8]) : nil
        case "2":
            let f = line.split(separator: " ", maxSplits: 9)
            return f.count == 10 ? f[9].split(separator: "\t").first.map(String.init) : nil
        case "u":
            let f = line.split(separator: " ", maxSplits: 10)
            return f.count == 11 ? String(f[10]) : nil
        default:
            return nil
        }
    }

    /// Files owned by TrackTasks itself don't count as "uncommitted work".
    private static func isTrackerFile(_ path: String) -> Bool {
        path == "about.md" || SpecDoc.isSpec(path) || path == "tasks/" || path.hasPrefix("tasks/") || Automation.isFile(path)
    }

    static func commits(_ url: URL, sinceDays: Int, limit: Int = 100) -> [Commit] {
        guard isRepo(url),
              let out = run(["log", "--since=\(sinceDays).days.ago", "--no-merges", "-n", "\(limit)", "--format=%cs%x09%s"], in: url)
        else { return [] }
        return out.split(separator: "\n").compactMap { l in
            let parts = l.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return Commit(date: String(parts[0]), subject: String(parts[1]))
        }
    }

    static func diffStat(_ url: URL) -> String {
        guard isRepo(url) else { return "" }
        return run(["diff", "--shortstat", "HEAD"], in: url)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// `git init` for projects without git, with a safe first commit:
/// secrets, personal-data dumps and huge files go to .gitignore instead of history.
enum GitInit {
    static let key = "autoGitInit"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static let defaultIgnore = """
    # Added by TrackTasks
    .DS_Store
    .env
    .env.*
    !.env.example
    *.pem
    *.key
    *.p12
    node_modules/
    vendor/
    __pycache__/
    *.pyc
    venv/
    .venv/
    build/
    dist/
    .build/
    DerivedData/
    target/
    coverage/
    *.log
    .claude/settings.local.json

    """

    static let maxFileSize = 10 * 1024 * 1024

    /// Returns a human-readable note when something was done, nil if the project already had git.
    static func ensure(_ url: URL) -> String? {
        guard !Git.isRepo(url) else { return nil }
        // Inside another repo (e.g. the whole category is one repo) — don't nest.
        if Git.run(["rev-parse", "--is-inside-work-tree"], in: url) != nil { return nil }
        guard Git.run(["init", "-q", "-b", "main"], in: url) != nil else { return "git init не удался" }

        let gi = url.appendingPathComponent(".gitignore")
        var ignore = (try? String(contentsOf: gi, encoding: .utf8)) ?? ""
        if ignore.isEmpty { ignore = defaultIgnore }
        let risky = riskyFiles(url)
        if !risky.isEmpty {
            if !ignore.hasSuffix("\n") { ignore += "\n" }
            ignore += "\n# TrackTasks: возможные секреты, личные данные или большие файлы — проверь перед коммитом\n"
            ignore += risky.map { "/" + $0 }.joined(separator: "\n") + "\n"
        }
        try? ignore.write(to: gi, atomically: true, encoding: .utf8)

        _ = Git.run(["add", "-A"], in: url)
        let committed = Git.run(["commit", "-q", "--no-verify", "-m", "Initial commit (TrackTasks)"], in: url) != nil
        var note = committed ? "Добавлен git и первый коммит" : "Добавлен git (первый коммит не удался — проверь git config user.name/email)"
        if !risky.isEmpty {
            note += ". Не попали в git (\(risky.count)): " + risky.prefix(5).joined(separator: ", ") + (risky.count > 5 ? "…" : "")
        }
        return note
    }

    /// Relative paths of files that shouldn't land in the first commit.
    static func riskyFiles(_ root: URL) -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return [] }
        let skip: Set<String> = Activity.skipDirs.union([".git", ".venv", ".build", ".next", ".idea", ".vscode"])
        let secretWords = ["secret", "password", "passwd", "credential", "token", "id_rsa", "id_ed25519", "private"]
        let dataWords = ["user", "customer", "client", "dump", "backup", "export", "personal", "phone", "email", "passport"]
        let dataExt: Set<String> = ["csv", "tsv", "sql", "sqlite", "sqlite3", "db", "xlsx", "xls", "json", "bak", "dump"]
        let prefix = root.path.count + 1
        var out: [String] = []
        var seen = 0
        for case let f as URL in e {
            seen += 1
            if seen > Activity.maxEntries { break }
            guard let v = try? f.resourceValues(forKeys: Set(keys)) else { continue }
            let name = f.lastPathComponent.lowercased()
            if v.isDirectory == true {
                if skip.contains(f.lastPathComponent) { e.skipDescendants() }
                continue
            }
            if name.hasPrefix(".env") && name != ".env.example" { continue } // already in default .gitignore
            let ext = f.pathExtension.lowercased()
            let stem = (name as NSString).deletingPathExtension
            let isSecret = secretWords.contains { stem.contains($0) } && !["swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt", "md", "html", "css"].contains(ext)
            let isData = dataExt.contains(ext) && dataWords.contains { stem.contains($0) }
            let isBig = (v.fileSize ?? 0) > maxFileSize
            if isSecret || isData || isBig {
                out.append(String(f.path.dropFirst(prefix)))
            }
        }
        return out.sorted()
    }
}
