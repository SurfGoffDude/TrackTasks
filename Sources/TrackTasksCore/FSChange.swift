import Foundation

/// What a batch of FSEvents means for the app.
public struct FSChange: Equatable, Sendable {
    public var tasks = Set<String>()     // about.md / spectrack.md / tasks/ changed → re-read project
    public var git = Set<String>()       // .git or working files changed → git status
    public var touched = Set<String>()   // working files changed → "last activity"
    public var docs = Set<String>()      // docs/ changed → re-index search
    public var structure = false         // category / project folders added or removed

    public init() {}

    public var isEmpty: Bool { tasks.isEmpty && docs.isEmpty && git.isEmpty && touched.isEmpty && !structure }

    /// - Parameters:
    ///   - projects: real project path → project id.
    ///   - rootReal: real path of the projects root.
    ///   - skipExempt: project paths that themselves contain a skip-dir segment.
    ///   - skipDirs: build / dependency folder names to ignore (node_modules, build…).
    ///   - ignoredFolders: folder names under the root that are never projects.
    public static func classify(_ events: [FileWatcher.Event], projects: [String: String],
                                rootReal: String, skipExempt: [String],
                                skipDirs: Set<String>, ignoredFolders: Set<String>) -> FSChange {
        var c = FSChange()
        for e in events {
            var path = e.path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            // Dropped events on a watched root (or anywhere outside a project) → full rescan via reload().
            if e.mustRescan && projects[path] == nil && !projects.keys.contains(where: { path.hasPrefix($0 + "/") }) {
                c.structure = true
                continue
            }
            // Cheap early drop of build/dependency churn (npm install, cargo build…) before walking up.
            // Segments inside .git/ are not checked (a branch may be named "build").
            if !e.mustRescan,
               path.split(separator: "/").prefix(while: { $0 != ".git" }).contains(where: { skipDirs.contains(String($0)) }),
               !skipExempt.contains(where: { path.hasPrefix($0) }) { continue }
            // Find the project folder by walking up the path.
            var dir = path
            var id: String?
            while dir.count > 1 {
                if let found = projects[dir] { id = found; break }
                dir = (dir as NSString).deletingLastPathComponent
            }
            guard let id else {
                // New / removed folder at category or project level → rescan.
                if path.hasPrefix(rootReal + "/") {
                    let parts = path.dropFirst(rootReal.count + 1).split(separator: "/")
                    let name = parts.last.map(String.init) ?? ""
                    if name.hasPrefix(".") || name.hasSuffix("-worktrees") || ignoredFolders.contains(name) { continue }
                    if parts.count <= 2 && (e.isDir || e.mustRescan) && (e.isCreateRemoveRename || e.mustRescan) { c.structure = true }
                }
                continue
            }
            if e.mustRescan { c.tasks.insert(id); c.git.insert(id); continue }
            if path == dir {
                if e.isCreateRemoveRename { c.structure = true }
                continue
            }
            let rel = String(path.dropFirst(dir.count + 1))
            if rel == Automation.folder { c.tasks.insert(id) }
            if rel == "about.md" || SpecDoc.isSpec(rel) || rel == "tasks" || rel.hasPrefix("tasks/") || Automation.isFile(rel) {
                c.tasks.insert(id)
            } else if rel == ".git" || rel.hasPrefix(".git/") {
                // objects/ and worktrees/ churn during background jobs without changing this checkout's status.
                if !rel.hasPrefix(".git/objects/") && !rel.hasPrefix(".git/worktrees/") && !rel.hasSuffix(".lock") {
                    c.git.insert(id)
                }
            } else {
                let parts = rel.split(separator: "/")
                if parts.contains(where: { $0.hasPrefix(".") || skipDirs.contains(String($0)) }) { continue }
                // A pipeline file is also an ordinary file of the project.
                if rel == Workflow.folder || (parts.count == 2 && parts[0] == Workflow.folder && rel.hasSuffix(".md")) { c.tasks.insert(id) }
                if rel.hasPrefix("docs/") { c.docs.insert(id) }
                c.touched.insert(id)
                c.git.insert(id)
            }
        }
        return c
    }
}
