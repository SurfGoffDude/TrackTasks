import Foundation
import Testing
@testable import TrackTasksCore

@Suite("README example")
struct ReadmeExampleTests {
    /// Example task from README.md must parse without losing fields.
    @Test func readmeExampleParses() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        let readme = try String(contentsOf: dir.appendingPathComponent("README.md"), encoding: .utf8)
        let lines = readme.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0 == "  ---" })
        let rest = lines[(start + 1)...]
        let close = try #require(rest.firstIndex { $0 == "  ---" })
        let end = try #require(lines[(close + 1)...].firstIndex { $0.hasPrefix("  ```") })
        let text = lines[start..<end].map { String($0.dropFirst(2)) }.joined(separator: "\n")
        let t = Codec.task(from: text, url: URL(fileURLWithPath: "/tmp/20261116-120000-example.md"))
        #expect(t.title == "Название")
        #expect(t.status == .todo)
        #expect(t.priority == .medium)
        #expect(t.created == "2026-11-16")
        #expect(t.completed.isEmpty)
        #expect(t.size == "m")
        #expect(t.agent == "claude")
        #expect(t.milestone == "v1.0")
        #expect(t.parent == "20261115-130000-volna.md")
        #expect(t.depends == ["20261115-140000-volna-c0.md"])
        #expect(t.files == ["Sources/App/Store.swift", "Sources/Core/"])
        #expect(t.repos == ["work/api"])
        #expect(t.body.contains("## Критерии готовности"))
        #expect(t.body.contains("## Заметки"))
    }
}
