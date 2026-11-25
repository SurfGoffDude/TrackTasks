import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

@MainActor @Suite("Список сессий приложения")
struct AppSessionsTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tt-appsessions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func survivesRestart() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let u = d.appendingPathComponent("sub/app-sessions.json")
        let a = AppSessions(url: u)
        a.add("one"); a.add("two"); a.add("one"); a.add("")
        #expect(AppSessions(url: u).ids == ["one", "two"])
    }

    @Test func brokenFileKeepsCopy() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let u = d.appendingPathComponent("app-sessions.json")
        try Data("{мусор".utf8).write(to: u)
        let a = AppSessions(url: u)
        #expect(a.ids.isEmpty)
        a.add("new")
        #expect(AppSessions(url: u).ids == ["new"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path).contains { $0.contains("corrupt-") })
    }

    /// A run of ClaudeProcess (queue, chat and one-shot requests all use it) with a stand-in for claude.
    private func run(fork: Bool, resume: String?, reports: [String], chat: Bool = false) async throws -> (all: Set<String>, chats: Set<String>) {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let script = d.appendingPathComponent("claude")
        let lines = reports.map { #"echo '{"type":"system","subtype":"init","session_id":"\#($0)"}'"# }
        // Reads stdin first: the process writes there right after the start.
        try (["#!/bin/sh", "read a; read b"] + lines).joined(separator: "\n")
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let list = AppSessions(url: d.appendingPathComponent("app-sessions.json"))
        let p = ClaudeProcess()
        p.sessions = list
        let chats = AppSessions(url: d.appendingPathComponent("chat-sessions.json"))
        p.chatSessions = chats
        await withCheckedContinuation { c in
            p.onExit = { _ in c.resume() }
            do {
                try p.start(ClaudeOptions(cwd: d, prompt: "x", systemPrompt: "", model: "", resume: resume, fork: fork,
                                          allowedTools: [], fromChat: chat), executable: script.path)
            } catch {
                Issue.record(error)
                c.resume()
            }
        }
        return (list.ids, chats.ids)
    }

    @Test func runIsRecorded() async throws {
        #expect(try await run(fork: false, resume: nil, reports: ["new"]).all == ["new"])
        #expect(try await run(fork: false, resume: "old", reports: ["old"]).all == ["old"])
    }

    @Test func forkRecordsOnlyNewID() async throws {
        #expect(try await run(fork: true, resume: "src", reports: ["src", "forked"]).all == ["forked"])
    }

    @Test func onlyChatRunIsMarked() async throws {
        let chat = try await run(fork: false, resume: nil, reports: ["c"], chat: true)
        #expect(chat.all == ["c"] && chat.chats == ["c"])
        let background = try await run(fork: false, resume: nil, reports: ["b"])
        #expect(background.all == ["b"] && background.chats.isEmpty)
    }

    @Test func backgroundRunsAreNotChat() {
        let d = URL(fileURLWithPath: "/p")
        #expect(!ClaudeOptions.oneShot(cwd: d, prompt: "x", model: .haiku).fromChat)
        #expect(!ClaudeOptions(AgentRequest(cwd: d, prompt: "x", model: "", access: .coding, isolated: true)).fromChat)
    }

    @Test func readsSessionsOfSavedChats() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let chats = d.appendingPathComponent("p__app")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        for (name, text) in [("a", #"{"sessionID":"one","title":"т"}"#), ("b", #"{"title":"без сессии"}"#), ("c", "{мусор")] {
            try Data(text.utf8).write(to: chats.appendingPathComponent(name + ".json"))
        }
        #expect(ChatHistory.sessionIDs(in: d) == ["one"])
        #expect(ChatHistory.sessionIDs(in: d.appendingPathComponent("нет")).isEmpty)
    }
}
