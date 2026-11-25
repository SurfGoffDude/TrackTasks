import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Источник сессий")
struct SessionSourceTests {
    private func of(_ e: [String], known: Bool = false, chat: Bool = false, cwd: String = "/p/app") -> Set<SessionSource> {
        SessionSource.of(entrypoints: e, known: known, chat: chat, inWorktree: SessionSource.isInWorktree(cwd: cwd, root: "/wt"))
    }

    @Test func terminal() { #expect(of(["cli"]) == [.mine]) }
    /// `known` covers both the app's own list and `sessionID` from queue.json.
    @Test func queueAndOldQueue() { #expect(of(["sdk-cli"], known: true) == [.app]) }
    @Test func worktree() {
        #expect(of(["sdk-cli"], cwd: "/wt/p__app/ab12cd") == [.app])
        #expect(of(["sdk-cli"], cwd: "/wt2/p__app/ab12cd") == [.other])
        #expect(of(["cli"], cwd: "/wt/p__app/ab12cd") == [.app, .mine])
    }
    @Test func foreignSDK() {
        #expect(of(["sdk-cli"]) == [.other])
        #expect(of(["sdk-py"]) == [.other])
        #expect(of(["claude-desktop"]) == [.other])
    }
    @Test func continuedInTerminal() {
        #expect(of(["sdk-cli", "cli"], known: true) == [.app, .mine])
        #expect(of(["sdk-cli", "cli"]) == [.mine])
    }
    /// The app's fork of a terminal session carries its `cli` lines.
    @Test func forkOfTerminalSession() { #expect(of(["cli", "sdk-cli"], known: true) == [.app]) }
    @Test func chat() {
        #expect(of(["sdk-cli"], known: true, chat: true) == [.app, .mine])
        // A chat from before the app kept its list of sessions.
        #expect(of(["sdk-cli"], chat: true) == [.app, .mine])
        #expect(of([], chat: true) == [.app, .mine])
    }
    @Test func chatContinuedInTerminal() { #expect(of(["sdk-cli", "cli"], known: true, chat: true) == [.app, .mine]) }
    @Test func noEntrypoint() {
        #expect(of([]) == [.other])
        #expect(of([], known: true) == [.app])
    }

    @Test func filter() {
        #expect(SessionFilter.allCases.filter { $0.matches([.app, .mine]) } == [.all, .mine, .app])
        #expect(SessionFilter.allCases.filter { $0.matches([.other]) } == [.all, .other])
    }

    @Test func parsesEntrypoints() throws {
        func line(_ e: String?, _ extra: String = "") -> String {
            SessionTests.user("текст", extra: (e.map { #","entrypoint":"\#($0)""# } ?? "") + extra)
        }
        #expect(try SessionTests.parse([line("sdk-cli"), line("sdk-cli"), line("cli", #","isSidechain":true"#)])?.info.entrypoints == ["sdk-cli"])
        #expect(try SessionTests.parse([line("sdk-cli"), line(nil), line("cli")])?.info.entrypoints == ["sdk-cli", "cli"])
        #expect(try SessionTests.parse([line(nil)])?.info.entrypoints == [])
    }
}
