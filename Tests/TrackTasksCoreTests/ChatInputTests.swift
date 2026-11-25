import Foundation
import Testing
@testable import TrackTasksCore

@Suite("Поле ввода чата")
struct ChatInputTests {
    private let commands: [ChatInput.Command] = [
        .init("new", "Новый"), .init("model", "Модель", values: ["auto", "opus", "sonnet"]), .init("обнови-about.md", "Обнови"),
    ]

    @Test func fileTokenAtTheEnd() {
        #expect(ChatInput.fileToken("@")?.query == "")
        #expect(ChatInput.fileToken("смотри @Sou")?.query == "Sou")
        #expect(ChatInput.fileToken("строка\n@a/b.swift")?.query == "a/b.swift")
        #expect(ChatInput.fileToken("@\"my fi")?.query == "my fi")
        #expect(ChatInput.fileToken("@types/@sc")?.query == "types/@sc")
    }

    @Test func notAFileToken() {
        for t in ["", "текст", "me@mail.com", "@a потом", "@\"a b\"", "@\"a b\" ", "@a ", "@a\n"] {
            #expect(ChatInput.fileToken(t) == nil, "\(t)")
        }
    }

    @Test func insertReplacesToken() throws {
        let t = "смотри @Sou"
        #expect(ChatInput.insert("Sources/A.swift", in: t, at: try #require(ChatInput.fileToken(t))) == "смотри @Sources/A.swift ")
        let q = "@\"my"
        let done = ChatInput.insert("my file.md", in: q, at: try #require(ChatInput.fileToken(q)))
        #expect(done == "@\"my file.md\" ")
        #expect(ChatInput.fileToken(done) == nil)
    }

    @Test func ranking() {
        let files = ["docs/Other/store.md", "Sources/Store.swift", "store/x.txt", "a/MyStore.swift", "README.md"]
        #expect(ChatInput.rank(files, query: "STORE") == ["Sources/Store.swift", "docs/Other/store.md", "store/x.txt", "a/MyStore.swift"])
        #expect(ChatInput.rank(files, query: "", limit: 2) == ["docs/Other/store.md", "Sources/Store.swift"])
        #expect(ChatInput.rank(files, query: "store", limit: 1).count == 1)
        #expect(ChatInput.rank(files, query: "нет").isEmpty)
    }

    @Test func parsesCommands() throws {
        let m = try #require(ChatInput.parse(" /Model  opus \n", commands: commands))
        #expect(m.command.name == "model" && m.argument == "opus")
        #expect(ChatInput.parse("/new", commands: commands)?.argument == "")
        #expect(ChatInput.parse("/обнови-about.md", commands: commands)?.command.name == "обнови-about.md")
    }

    @Test func ordinaryText() {
        for t in ["", "/", "/Users/me/new", "/compact", "/newer", "скажи /new", "//new"] {
            #expect(ChatInput.parse(t, commands: commands) == nil, "\(t)")
            #expect(t == "/" || ChatInput.completions(t, commands: commands).isEmpty, "\(t)")
        }
    }

    @Test func completions() {
        #expect(ChatInput.completions("/", commands: commands).count == 3)
        #expect(ChatInput.completions("/N", commands: commands) == [.init(text: "/new", hint: "Новый", runs: true)])
        #expect(ChatInput.completions("/mo", commands: commands) == [.init(text: "/model ", hint: "Модель", runs: false)])
        #expect(ChatInput.completions("/model o", commands: commands).map(\.text) == ["/model opus"])
        #expect(ChatInput.completions("/model ", commands: commands).count == 3)
        #expect(ChatInput.completions("/new\nтекст", commands: commands).isEmpty)
    }

    @Test func slug() {
        #expect(ChatInput.slug("Обнови about.md") == "обнови-about.md")
        #expect(ChatInput.slug("Задачи → новый формат") == "задачи-новый-формат")
        #expect(ChatInput.slug("Что сделано?") == "что-сделано")
    }

    @Test func context() {
        #expect(ChatInput.context(800, window: nil) == "800")
        #expect(ChatInput.context(41_400, window: 200_000) == "41k · 21 %")
        #expect(ChatInput.context(41_400, window: 0) == "41k")
    }
}
