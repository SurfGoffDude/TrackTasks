import Foundation
import Testing
@testable import TrackTasksCore

@Suite("PullRequest")
struct PullRequestTests {
    @Test func viewOpen() {
        let pr = PullRequest.parse(#"{"baseRefName":"main","headRefName":"tracktasks/x","headRefOid":"abc","isDraft":true,"mergeCommit":null,"number":7,"state":"OPEN","url":"https://github.com/o/r/pull/7"}"#)
        #expect(pr == PullRequest(number: 7, url: "https://github.com/o/r/pull/7", isDraft: true,
                                  head: "tracktasks/x", headOid: "abc", base: "main"))
    }

    @Test func viewMergedAndClosed() {
        let m = PullRequest.parse(#"{"mergeCommit":{"oid":"def"},"number":7,"state":"MERGED","url":"u"}"#)
        #expect(m?.state == .merged)
        #expect(m?.mergeOid == "def")
        #expect(PullRequest.parse(#"{"number":7,"state":"CLOSED","url":"u"}"#)?.state == .closed)
    }

    @Test func brokenJSON() {
        #expect(PullRequest.parse("") == nil)
        #expect(PullRequest.parse("{}") == nil)
        #expect(PullRequest.parse(#"{"number":7,"state":"WHAT","url":"u"}"#) == nil)
        #expect(PullRequest.parseList("oops") == nil)
        #expect(PullRequest.parseList(#"[{"number":7,"state":"WHAT","url":"u"}]"#) == nil)
    }

    @Test func list() {
        #expect(PullRequest.parseList("[]") == [])
        #expect(PullRequest.parseList(#"[{"number":7,"state":"OPEN","url":"u"}]"#)?.map(\.number) == [7])
    }

    @Test func created() {
        #expect(PullRequest.parseCreated("Warning: 1 uncommitted change\nhttps://github.com/o/r/pull/12\n")?.number == 12)
        #expect(PullRequest.parseCreated("nothing") == nil)
    }

    @Test func linkRoundTripAndLive() throws {
        var l = PullRequestLink(pr: PullRequest(number: 1, url: "u"), remote: "origin", pushedOid: "a")
        #expect(try JSONDecoder().decode(PullRequestLink.self, from: JSONEncoder().encode(l)) == l)
        #expect(l.isLive)
        l.pr.state = .closed
        #expect(!l.isLive)
        l.pr.state = .merged
        #expect(l.isLive)
        l.leftover = true
        #expect(!l.isLive)
    }

    @Test func cleanup() {
        func d(_ s: PullRequest.State = .merged, pulled: Bool = true, dirty: Bool = false, tip: String = "a",
               head: String = "a", inMain: Bool = false) -> PullRequestCleanup {
            .decide(state: s, pulled: pulled, dirty: dirty, tip: tip, pushed: "a", head: head, tipInMain: inMain)
        }
        #expect(d(.open) == .none)
        #expect(d(.closed) == .none)
        #expect(d(pulled: false) == .waitPull)
        #expect(d(dirty: true) == .dirty)
        #expect(d() == .clean)
        #expect(d(tip: "b") == .newCommits)
        #expect(d(tip: "b", head: "b") == .clean)
        #expect(d(tip: "b", inMain: true) == .clean)
        #expect(d(tip: "", head: "") == .newCommits)
    }

    @Test(arguments: ["git@github.com:o/r.git", "https://github.com/o/r", "https://x:tok@github.com/o/r.git/",
                      "ssh://git@github.com:22/o/r.git", "ssh://git@ssh.github.com:443/o/r.git"])
    func remote(_ url: String) {
        #expect(GitHubRepo.parse(url)?.slug == "github.com/o/r")
    }

    @Test func notRemote() {
        #expect(GitHubRepo.parse("/tmp/repo.git") == nil)
        #expect(GitHubRepo.parse("file:///o/r") == nil)
        #expect(GitHubRepo.parse("") == nil)
    }

    @Test func maskedRemote() {
        #expect(GitHubRepo.masked("https://u:p@h@github.com/o/r") == "https://github.com/o/r")
        #expect(GitHubRepo.masked("git@github.com:o/r.git") == "git@github.com:o/r.git")
    }

    @Test func drafts() {
        #expect(PullRequestDraft.local(title: "T", taskText: "a\n## Итог\nсделано\n## Заметки\n- x") == .init(title: "T", body: "сделано"))
        #expect(PullRequestDraft.parse("```\n# Title\n\n- a\n```") == .init(title: "Title", body: "- a"))
        #expect(PullRequestDraft.parse("Only") == .init(title: "Only", body: ""))
        #expect(PullRequestDraft.parse(" \n") == nil)
    }

    @Test func preflight() {
        let repo = GitHubRepo.parse("git@github.com:o/r.git")
        func p(_ r: GitHubRepo?, remote: Bool = true, gh: Bool = true, auth: Bool = true) -> String? {
            PullRequestPreflight.problem(hasRemote: remote, repo: r, hasGH: gh, loggedIn: auth)
        }
        #expect(p(nil, remote: false)?.contains("нет remote") == true)
        #expect(p(nil)?.contains("не похож") == true)
        #expect(p(repo, gh: false)?.contains("brew install gh") == true)
        #expect(p(repo, auth: false)?.contains("gh auth login --hostname github.com") == true)
        #expect(p(repo) == nil)
    }
}
