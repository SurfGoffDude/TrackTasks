import Foundation

/// git arguments of a job's worktree. Both commands leave the main folder's files and index alone.
public enum WorktreeGit {
    public static func add(branch: String, path: String, base: String) -> [String] {
        ["worktree", "add", "-b", branch, path, base]
    }

    /// Everything the job changed, without tracker files (they live in the main folder) and linked dependencies.
    public static func stage(excluding linked: [String]) -> [String] {
        ["add", "-A", "--", ".", ":(exclude)tasks", ":(exclude)about.md", ":(exclude,icase)spectrack.md", ":(exclude).claude",
         ":(exclude)\(PreviewFolder.name)",
         ":(exclude,glob)\(Automation.folder)/*.md"]
            + linked.map { ":(exclude)\($0)" }
    }
}
