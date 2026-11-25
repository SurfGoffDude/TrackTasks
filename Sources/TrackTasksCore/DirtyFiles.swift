import Foundation

/// Uncommitted changes in a project's main folder that matter for worktree jobs.
/// Tracker files (tasks/, about.md, spectrack.md, automations/*.md, .claude/) live only in the main folder, so they never block or conflict.
public enum DirtyFiles {
    /// Paths that don't count as "code" changes.
    public static func isTrackerFile(_ path: String) -> Bool {
        path == "about.md" || SpecDoc.isSpec(path) || path == "tasks" || path.hasPrefix("tasks/")
            || path == ".claude" || path.hasPrefix(".claude/")
            || path == PreviewFolder.name || path.hasPrefix(PreviewFolder.name + "/") || Automation.isFile(path)
    }

    /// Parse `git status --porcelain -z -uall` output into changed paths (renames give both names).
    public static func parsePorcelainZ(_ out: String) -> [String] {
        var paths: [String] = []
        var parts = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = parts.popFirst() {
            guard entry.count > 3 else { continue }
            let xy = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))
            // Rename/copy: the original path follows as a separate NUL-terminated field.
            if xy.contains("R") || xy.contains("C"), let orig = parts.popFirst() { paths.append(orig) }
        }
        return paths
    }

    /// Changed paths that are real code changes (tracker files filtered out), sorted and unique.
    public static func significant(_ paths: [String]) -> [String] {
        Array(Set(paths.filter { !isTrackerFile($0) })).sorted()
    }

    /// Files touched by the branch that also have uncommitted changes in the main folder.
    public static func overlap(branch: [String], dirty: [String]) -> [String] {
        let d = Set(dirty)
        return Array(Set(branch.filter { d.contains($0) })).sorted()
    }

    /// Short human list: first few names and "+N".
    public static func summary(_ paths: [String], limit: Int = 3) -> String {
        let head = paths.prefix(limit).joined(separator: ", ")
        return paths.count > limit ? head + " +\(paths.count - limit)" : head
    }
}
