import Foundation

/// The user's and the project's `.rules`. A rule with `allow` runs its command unasked and outside the sandbox, and
/// app-server can't ignore rules, so Codex isn't started with one.
public enum CodexRules {
    /// The first rules file (or unreadable folder) that may allow something.
    public static func blocking(_ dirs: [URL]) -> String? {
        let fm = FileManager.default
        for dir in dirs {
            let names: [String]
            do { names = try fm.contentsOfDirectory(atPath: dir.path) } catch {
                let code = (error as NSError).code
                if code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError { continue }
                return dir.path
            }
            for name in names.sorted() where name.lowercased().hasSuffix(".rules") {
                let file = dir.appendingPathComponent(name)
                guard let text = try? String(contentsOf: file, encoding: .utf8), onlyRestricts(text) else { return file.path }
            }
        }
        return nil
    }

    /// Where Codex may look: its home, the system folder, `.codex/rules` of the folders and everything above them
    /// (wider than needed on purpose: for a worktree the main folder comes in through `addDirs`).
    public static func dirs(codexHome: URL, folders: [URL]) -> [URL] {
        var out = [codexHome.appendingPathComponent("rules"), URL(fileURLWithPath: "/etc/codex/rules")]
        for folder in folders {
            var path = CodexPolicy.real(folder.path) ?? folder.standardizedFileURL.path
            while true {
                out.append(URL(fileURLWithPath: path).appendingPathComponent(".codex/rules"))
                if path == "/" || path.isEmpty { break }
                path = (path as NSString).deletingLastPathComponent
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }

    /// True only for a file of plain `prefix_rule(…)` calls, each with a literal "prompt" or "forbidden" (no decision
    /// means allow — checked with 0.162). The format is Starlark: anything else counts as allowing.
    static func onlyRestricts(_ text: String) -> Bool {
        // Comments go away, a string becomes one character: R — restricting decision, S — any other.
        var code = "", rest = Substring(text.replacingOccurrences(of: "\r\n", with: "\n"))
        while let c = rest.popFirst() {
            if c == "#" {
                rest = rest.drop { $0 != "\n" }
            } else if c == "\"" || c == "'" {
                guard let end = rest.firstIndex(of: c) else { return false }
                let s = rest[..<end]
                if s.contains("\\") || s.contains("\n") { return false }
                rest = rest[rest.index(after: end)...]
                if rest.first == "\"" || rest.first == "'" { return false }  // triple quotes
                code += s == "prompt" || s == "forbidden" ? "R" : "S"
            } else if c == "R" || c == "S" {
                return false
            } else {
                code.append(c)
            }
        }
        let value = #"(?:[RS]|\[[RS\[\],\s]*\])"#
        let other = #"(?:pattern|match|not_match|justification)\s*=\s*\#(value)"#
        let call = #"prefix_rule\s*\(\s*(?:\#(other)\s*,\s*)*decision\s*=\s*R\s*(?:,\s*\#(other)\s*)*,?\s*\)"#
        return code.range(of: #"\A\s*(?:\#(call)\s*)*\z"#, options: .regularExpression) != nil
    }
}
