import Foundation

/// Frontmatter `files:` — files and folders a task is going to change. A hint for the queue (tasks with common
/// files don't run together), not a limit of the agent's rights.
public enum TaskFiles {
    /// Path split into parts for comparing; nil — not a relative path inside the project.
    /// Case and Unicode form don't matter, as on the macOS file system.
    static func parts(_ path: String) -> [String]? {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !p.hasPrefix("/"), !p.hasPrefix("~"), !p.contains("*"), !p.contains("\\") else { return nil }
        let out = p.split(separator: "/").filter { $0 != "." }
            .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        return out.isEmpty || out.contains("..") ? nil : out
    }

    public static func isValid(_ path: String) -> Bool { parts(path) != nil }

    /// What can be written to `files: […]` and read back unchanged.
    static func isWritable(_ path: String) -> Bool {
        isValid(path) && !path.contains { ",\"#".contains($0) || $0.isNewline }
            && path == path.trimmingCharacters(in: .whitespaces)
    }

    /// Common paths of two lists, the narrower one of each pair («Sources/» and «Sources/A.swift» → «Sources/A.swift»).
    public static func overlap(_ a: [String], _ b: [String]) -> [String] {
        let right = b.compactMap { p in parts(p).map { (p, $0) } }
        var seen = Set<[String]>(), out: [String] = []
        for p in a {
            guard let l = parts(p) else { continue }
            for (q, r) in right where l.starts(with: r) || r.starts(with: l) {
                let narrow = l.count >= r.count
                if seen.insert(narrow ? l : r).inserted { out.append(narrow ? p : q) }
            }
        }
        return out
    }

    /// Entries of a text field: commas or new lines, no repeats.
    public static func split(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Project files named in the «План» section. `known`: project files (`git ls-files`). A bare name counts when
    /// only one file has it; an unknown path counts as a new file when its folder exists.
    public static func suggest(plan: String, known: [String]) -> [String] {
        var files: [[String]: String] = [:], byName: [String: [String]] = [:], folders: [[String]: String] = [:]
        for k in known {
            guard let p = parts(k), let name = p.last else { continue }
            files[p] = k
            byName[name, default: []].append(k)
            let raw = k.split(separator: "/").map(String.init)
            guard raw.count == p.count else { continue }
            for n in 1..<max(p.count, 1) {
                let f = Array(p.prefix(n))
                if folders[f] == nil { folders[f] = raw.prefix(n).joined(separator: "/") + "/" }
            }
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`«»\"'(),;<>|*"))
        var out: [String] = []
        func add(_ p: String) {
            if isWritable(p), !DirtyFiles.isTrackerFile(p), !out.contains(p) { out.append(p) }
        }
        for token in plan.components(separatedBy: separators) where !token.isEmpty && !token.contains("://") {
            // «Jobs.swift:120», «Jobs.swift.» at the end of a sentence.
            var t = token
            if let r = t.range(of: #":[0-9]+([-:–][0-9]+)?[.:]?$"#, options: .regularExpression) { t.removeSubrange(r) }
            while let c = t.last, ".:!?".contains(c) { t.removeLast() }
            guard let p = parts(t) else { continue }
            if let f = files[p] { add(f); continue }
            // A one-word folder («docs») is a word of the text unless it is written as «docs/».
            if let f = folders[p], p.count > 1 || t.hasSuffix("/") { add(f); continue }
            if p.count == 1 {
                if t.contains("."), let k = byName[p[0]], k.count == 1 { add(k[0]) }
            } else if !t.hasSuffix("/"), p.last!.contains("."), folders[Array(p.dropLast())] != nil {
                add(t.hasPrefix("./") ? String(t.dropFirst(2)) : t)
            }
        }
        return out
    }
}
