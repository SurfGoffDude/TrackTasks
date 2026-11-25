import Foundation

/// Finds project folders: `<root>/<category>/<project>` plus folders added by hand. Shared by the app and `tt`.
public enum ProjectScan {
    public static let ignoredFolders: Set<String> = ["keys", "templates", "node_modules", "fonts"]

    public struct Entry: Hashable, Sendable {
        public let url: URL
        /// nil for folders added by hand.
        public let category: String?
    }

    public static func subdirs(_ url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !ignoredFolders.contains($0.lastPathComponent) && !$0.lastPathComponent.hasSuffix("-worktrees") }
    }

    public static func entries(root: URL, extras: [String] = []) -> [Entry] {
        var out: [Entry] = []
        for cat in subdirs(root) {
            for dir in subdirs(cat) { out.append(Entry(url: dir, category: cat.lastPathComponent)) }
        }
        var seen = Set(out.map { $0.url.standardizedFileURL.path })
        for path in extras {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                  seen.insert(url.path).inserted else { continue }
            out.append(Entry(url: url, category: nil))
        }
        return out
    }

    /// `mainCheckout`, but a `.git` file is believed only when that repository lists the worktree too:
    /// anybody can write a `gitdir:` line. nil when it is not listed.
    static func verifiedCheckout(_ dir: URL) -> URL? {
        let main = mainCheckout(dir)
        guard main.path != dir.standardizedFileURL.path else { return main }
        var up = dir.standardizedFileURL
        while up.path != "/", !FileManager.default.fileExists(atPath: up.appendingPathComponent(".git").path) {
            up = up.deletingLastPathComponent()
        }
        let git = up.appendingPathComponent(".git")
        guard let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
        let raw = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let admin = URL(fileURLWithPath: raw, relativeTo: up).standardizedFileURL
        guard let back = try? String(contentsOf: admin.appendingPathComponent("gitdir"), encoding: .utf8) else { return nil }
        let listed = URL(fileURLWithPath: back.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: admin)
        return listed.resolvingSymlinksInPath().path == git.resolvingSymlinksInPath().path ? main : nil
    }

    /// Same folder in the main checkout when `dir` is inside a linked git worktree, else `dir`.
    /// Task files live only in the main folder (R12).
    public static func mainCheckout(_ dir: URL) -> URL {
        let start = dir.standardizedFileURL
        var up = start
        var below: [String] = []
        while true {
            let git = up.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                guard !isDir.boolValue, let text = try? String(contentsOf: git, encoding: .utf8),
                      text.hasPrefix("gitdir:") else { return start }
                let raw = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                let gitdir = URL(fileURLWithPath: raw, relativeTo: up).standardizedFileURL
                let common = gitdir.deletingLastPathComponent().deletingLastPathComponent()
                guard gitdir.deletingLastPathComponent().lastPathComponent == "worktrees",
                      common.lastPathComponent == ".git" else { return start }
                return below.reversed().reduce(common.deletingLastPathComponent()) { $0.appendingPathComponent($1) }
            }
            if up.path == "/" { return start }
            below.append(up.lastPathComponent)
            up = up.deletingLastPathComponent()
        }
    }
}
