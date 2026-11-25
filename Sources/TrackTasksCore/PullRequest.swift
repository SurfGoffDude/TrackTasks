import Foundation

/// A pull request as `gh pr … --json` reports it (`PullRequest.jsonFields`).
public struct PullRequest: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case open = "OPEN", merged = "MERGED", closed = "CLOSED" }

    public var number: Int
    public var url: String
    public var state: State
    public var isDraft: Bool
    public var head: String
    public var headOid: String
    public var base: String
    /// Commit that landed in the base branch (merge, squash or the last rebased one).
    public var mergeOid: String?

    public init(number: Int, url: String, state: State = .open, isDraft: Bool = false, head: String = "",
                headOid: String = "", base: String = "", mergeOid: String? = nil) {
        self.number = number
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.head = head
        self.headOid = headOid
        self.base = base
        self.mergeOid = mergeOid
    }

    public static let jsonFields = "number,url,state,isDraft,headRefName,headRefOid,baseRefName,mergeCommit"

    private struct Raw: Decodable {
        struct Commit: Decodable { let oid: String }
        let number: Int
        let url: String
        let state: String
        let isDraft: Bool?
        let headRefName: String?
        let headRefOid: String?
        let baseRefName: String?
        let mergeCommit: Commit?

        var value: PullRequest? {
            guard let s = State(rawValue: state.uppercased()) else { return nil }
            return PullRequest(number: number, url: url, state: s, isDraft: isDraft ?? false, head: headRefName ?? "",
                               headOid: headRefOid ?? "", base: baseRefName ?? "",
                               mergeOid: mergeCommit.flatMap { $0.oid.isEmpty ? nil : $0.oid })
        }
    }

    /// `gh pr view --json …`; nil = broken JSON, missing field or unknown state.
    public static func parse(_ json: String) -> PullRequest? {
        try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)).value
    }

    /// `gh pr list --json …`; nil = broken JSON.
    public static func parseList(_ json: String) -> [PullRequest]? {
        guard let raw = try? JSONDecoder().decode([Raw].self, from: Data(json.utf8)) else { return nil }
        let list = raw.compactMap(\.value)
        return list.count == raw.count ? list : nil
    }

    /// `gh pr create` prints the URL of the new pull request (possibly after warnings).
    public static func parseCreated(_ out: String) -> PullRequest? {
        for line in out.split(whereSeparator: \.isNewline).reversed() {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("https://"), let r = s.range(of: "/pull/"), let n = Int(s[r.upperBound...]) else { continue }
            return PullRequest(number: n, url: s)
        }
        return nil
    }
}

/// Pull request of a job's branch.
public struct PullRequestLink: Codable, Sendable, Equatable {
    public var pr: PullRequest
    public var remote: String
    /// Branch tip the app pushed last.
    public var pushedOid: String
    /// Merged and pulled, but the branch got commits that were never pushed: it needs a decision of its own.
    public var leftover = false
    /// Checks and reviews as last seen; nil = not known.
    public var status: PullRequestStatus?
    /// Green checks of `pushedOid`; a new push makes a new link, so it starts over.
    public var confirmation: CIConfirmation?

    public init(pr: PullRequest, remote: String, pushedOid: String) {
        self.pr = pr
        self.remote = remote
        self.pushedOid = pushedOid
    }

    /// The branch is handled by the pull request: no local merge.
    public var isLive: Bool { pr.state == .open || (pr.state == .merged && !leftover) }
}

/// What to do with the local branch of a pull request.
public enum PullRequestCleanup: Sendable, Equatable {
    case none, waitPull, dirty, newCommits, clean

    public static func decide(state: PullRequest.State, pulled: Bool, dirty: Bool, tip: String, pushed: String,
                              head: String, tipInMain: Bool) -> PullRequestCleanup {
        guard state == .merged else { return .none }
        guard pulled else { return .waitPull }
        if dirty { return .dirty }
        let known = !tip.isEmpty && (tip == pushed || tip == head)
        return known || tipInMain ? .clean : .newCommits
    }
}

/// `host/owner/repo` of a git remote URL.
public struct GitHubRepo: Sendable, Equatable {
    public let host: String
    public let path: String
    public var slug: String { host + "/" + path }

    public static func parse(_ url: String) -> GitHubRepo? {
        let s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = "", rest = ""
        if s.contains("://") {
            guard let c = URLComponents(string: s), ["https", "http", "ssh", "git"].contains(c.scheme?.lowercased() ?? "") else { return nil }
            host = c.host ?? ""
            rest = c.path
        } else if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") {
            host = s[..<colon].split(separator: "@").last.map(String.init) ?? ""
            rest = String(s[s.index(after: colon)...])
        }
        var parts = rest.split(separator: "/").map(String.init)
        guard !host.isEmpty, parts.count == 2 else { return nil }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        guard !parts[1].isEmpty else { return nil }
        // GitHub's ssh-over-443 endpoint.
        host = host.lowercased() == "ssh.github.com" ? "github.com" : host.lowercased()
        return GitHubRepo(host: host, path: parts.joined(separator: "/"))
    }

    /// Remote URL without the password or token it may carry — safe to show.
    public static func masked(_ url: String) -> String {
        guard let scheme = url.range(of: "://") else { return url }
        let end = url[scheme.upperBound...].firstIndex(of: "/") ?? url.endIndex
        guard let at = url[scheme.upperBound..<end].lastIndex(of: "@") else { return url }
        return String(url[..<scheme.upperBound]) + String(url[url.index(after: at)...])
    }
}

/// Title and text of a new pull request.
public struct PullRequestDraft: Sendable, Equatable {
    public var title: String
    public var body: String

    /// Without Claude: the task's title and its «Итог».
    public static func local(title: String, taskText: String) -> PullRequestDraft {
        var body: [String] = []
        var inside = false
        for line in taskText.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                inside = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "итог"
            } else if inside {
                body.append(line)
            }
        }
        return PullRequestDraft(title: title, body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Claude's answer: first line — title, the rest — text.
    public static func parse(_ answer: String) -> PullRequestDraft? {
        var lines = answer.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.count > 1, lines[0].hasPrefix("```"), lines[lines.count - 1] == "```" {
            lines.removeFirst()
            lines.removeLast()
        }
        guard let first = lines.first else { return nil }
        let title = first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return PullRequestDraft(title: title, body: lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Why a pull request can't be created here.
public enum PullRequestPreflight {
    public static func problem(hasRemote: Bool, repo: GitHubRepo?, hasGH: Bool, loggedIn: Bool) -> String? {
        if !hasRemote { return "У репозитория нет remote. Добавь его: git remote add origin <адрес>" }
        guard let repo else { return "Адрес remote не похож на GitHub (нужен вид host/владелец/репозиторий)" }
        if !hasGH { return "Не найден GitHub CLI (gh). Установи: brew install gh, затем gh auth login" }
        if !loggedIn { return "gh не авторизован для \(repo.host). Выполни: gh auth login --hostname \(repo.host)" }
        return nil
    }
}
