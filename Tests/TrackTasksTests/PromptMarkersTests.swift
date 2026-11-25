import Testing
@testable import TrackTasks

/// Parsers depend on these marker strings in prompts; a rewording must not drop them.
@Suite struct PromptMarkersTests {
    @Test func codingPromptKeepsQuestionsAndFindingsSections() {
        let p = ClaudePrompts.codingSystem(name: "P", path: "/tmp/p")
        #expect(p.contains("## Вопросы"))
        #expect(p.contains("## Находки"))
        #expect(p.contains("Ответ:"))
    }

    @Test func fixPromptKeepsReviewSeverityWords() {
        let p = ClaudePrompts.reviewSystem(name: "P", path: "/tmp/p")
        #expect(p.contains("spectrack.md"))
    }
}
