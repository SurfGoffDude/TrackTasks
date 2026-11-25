import Foundation
import TrackTasksCore

/// New commits of local branches, by comparing refs. No hooks in the repository. Synchronous: off the main thread.
enum GitEvents {
    struct Change: Sendable {
        var refs: [String: String]
        /// nil: nothing to report (first look, rebase, a new or deleted branch).
        var payload: EventPayload?
    }
    static let maxCommits = 20

    /// nil: git did not answer.
    static func change(in url: URL, branches: [String], before: [String: String]?) -> Change? {
        guard Git.isRepo(url), let out = Git.run(["for-each-ref", "--format=%(objectname) %(refname)", "refs/heads"], in: url) else { return nil }
        var refs: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, isHash(parts[0]), parts[1].hasPrefix("refs/heads/") else { continue }
            let branch = String(parts[1].dropFirst(11))
            if EventPayload.isOwnBranch(branch) || !(branches.isEmpty || branches.contains(branch)) { continue }
            refs[branch] = parts[0]
        }
        guard let before else { return Change(refs: refs, payload: nil) }
        var fields: [EventPayload.Field] = [], left = maxCommits
        for (branch, new) in refs.sorted(by: { $0.key < $1.key }) {
            // Only a moved-forward branch has new commits: a rebase or reset does not. Git is given hashes, never names.
            guard let old = before[branch], old != new, isHash(old),
                  Git.run(["merge-base", "--is-ancestor", old, new], in: url) != nil else { continue }
            fields += [.init("branch", branch), .init("before", old), .init("after", new)]
            guard left > 0 else { continue }
            let log = Git.run(["-c", "log.showSignature=false", "log", "--no-color", "-n", "\(left)", "--format=%h %s", "\(old)..\(new)"], in: url) ?? ""
            left -= log.split(separator: "\n").count
            fields.append(.init("commits", log))
        }
        return Change(refs: refs, payload: fields.isEmpty ? nil : EventPayload(name: "git: новые коммиты", fields: fields))
    }

    private static func isHash(_ s: String) -> Bool {
        (s.utf8.count == 40 || s.utf8.count == 64) && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
