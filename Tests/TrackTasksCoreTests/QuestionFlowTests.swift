import Testing
@testable import TrackTasksCore

@Suite struct QuestionFlowTests {
    let texts = ["A?", "B?", "C?"]

    @Test func firstUnansweredIsShown() {
        var d = QuestionDraft()
        #expect(d.current(texts) == 0 && d.current([]) == 0)
        d.choose("A?", .decide)
        #expect(d.current(texts) == 1)
        d.choose("B?", .decide)
        d.choose("C?", .decide)
        #expect(d.current(texts) == 2)
    }

    @Test func stepsStayInBounds() {
        var d = QuestionDraft()
        d.go(-1, texts)
        #expect(d.current(texts) == 0)
        d.go(1, texts)
        // An answer doesn't move the person to another question.
        d.choose("B?", .decide)
        #expect(d.current(texts) == 1)
        d.go(1, texts)
        d.go(1, texts)
        #expect(d.current(texts) == 2)
        // The shown question is gone: the first one without an answer.
        #expect(d.current(["B?", "A?"]) == 1)
        d.go(1, [])
    }

    @Test func readyWhenAllAnswered() {
        var d = QuestionDraft()
        #expect(!d.isReady([]) && !d.isReady(texts) && d.missing(texts) == 0)
        d.choose("A?", .option("один  вариант"))
        d.type("B?", "  \n ")
        #expect(d.missing(texts) == 1)
        d.type("B?", "две\nстроки")
        d.choose("C?", .decide)
        #expect(d.isReady(texts) && d.missing(texts) == nil)
        #expect(d.answers(texts).map(\.answer) == ["один вариант", "две строки", "реши сам"])
        #expect(d.answers(texts).map(\.question) == texts)
        d.type("B?", "")
        #expect(!d.isReady(texts))
    }

    @Test func typedTextSurvivesAnOption() {
        var d = QuestionDraft()
        d.type("A?", "мой")
        d.choose("A?", .option("да"))
        // The field reports the same text again: not an edit.
        d.type("A?", "мой")
        #expect(d.answer("A?") == "да" && d.ownText("A?") == "мой")
        d.choose("A?", .own)
        #expect(d.answer("A?") == "мой")
    }

    @Test func equalQuestionsAreAnsweredApart() {
        let same = ["A?", "A?"]
        let k = QuestionDraft.keys(same)
        var d = QuestionDraft()
        d.choose(k[0], .option("да"))
        #expect(!d.isReady(k))
        d.choose(k[1], .option("нет"))
        #expect(d.answers(same).map(\.answer) == ["да", "нет"])
    }

    @Test func statusAndCounter() {
        func s(_ open: Int, _ undelivered: Bool = false, busy: Bool = false, closed: Bool = false) -> QuestionStatus {
            .of(open: open, undelivered: undelivered, busy: busy, closed: closed)
        }
        #expect(s(0) == .none && s(2) == .ask(2) && s(2, true) == .ask(2) && s(0, true) == .send)
        #expect(s(2, busy: true) == .none && s(2, closed: true) == .none && s(0, true, closed: true) == .none)
        #expect(s(2).line == "Ждёт ответа: 2" && !s(0).needsPerson && s(0, true).needsPerson)
        #expect(QuestionStatus.counter([.none]) == nil)
        #expect(QuestionStatus.counter([.ask(5), .none, .send]) == "Ждут ответа: 2")
    }

    @Test func nothingOfTheSectionIsLost() {
        let t = """
        ## Вопросы
        Введение.

        1. Длинный вопрос
           с продолжением?
           - да (рекомендую)
           - нет

           ```
           - код
           ```
           Ответ: да
        2. B?

        ## Итог
        """
        let q = AgentQuestions.parse(t)
        #expect(AgentQuestions.preamble(t) == "Введение.")
        #expect(q[0].details == "с продолжением?\n\n```\n- код\n```" && q[0].answer == "да" && q[1].details.isEmpty)
        let free = AgentQuestions.parse("## Вопросы\nчто делать?\n```\nкод\n```")
        #expect(free[0].text == "что делать?" && free[0].details == "```\nкод\n```")
    }
}
