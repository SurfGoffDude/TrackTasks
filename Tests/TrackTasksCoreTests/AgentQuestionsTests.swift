import Foundation
import Testing
@testable import TrackTasksCore

@Suite("AgentQuestions")
struct AgentQuestionsTests {
    let strict = """
    ---
    title: "T"
    ---

    Описание.

    ## Вопросы
    1. Как агент входит в аккаунт?
       - Токен в Keychain (рекомендую)
       - Вход внутри контейнера
       Ответ: Токен в Keychain
    2. Нужен ли кеш?
       - Да
       - Нет

    ## Заметки
    - ничего
    """

    @Test func strictFormat() {
        let qs = AgentQuestions.parse(strict)
        #expect(qs.count == 2)
        #expect(qs[0].text == "Как агент входит в аккаунт?")
        #expect(qs[0].options == [.init(text: "Токен в Keychain", recommended: true),
                                  .init(text: "Вход внутри контейнера", recommended: false)])
        #expect(qs[0].answer == "Токен в Keychain")
        #expect(qs[1].isOpen)
        #expect(AgentQuestions.open(in: strict).map(\.text) == ["Нужен ли кеш?"])
        #expect(AgentQuestions.open(in: strict, done: true).isEmpty)
    }

    @Test func freeFormNumberedWithNestedNotes() {
        let t = """
        ## Вопросы
        1. Какой образ взять?
           - node:22-alpine, там нет git
        2. Куда класть токен?
        """
        let qs = AgentQuestions.parse(t)
        #expect(qs.count == 2)
        #expect(qs[1].options.isEmpty)
        #expect(qs.allSatisfy { $0.isOpen })
    }

    @Test func letteredItems() {
        let t = """
        ## Вопросы
        - Выбрать подход?
          - **А.** Через сокет (рекомендую)
          - **Б.** Через файл
        """
        let q = AgentQuestions.parse(t)[0]
        #expect(q.options.map(\.text) == ["**А.** Через сокет", "**Б.** Через файл"])
        #expect(q.options[0].recommended)
    }

    @Test func sectionWithoutItemsIsOneQuestion() {
        let t = "## Вопросы\nНе понятно, какой формат нужен.\nУточни, пожалуйста.\n\n## Заметки\n- x\n"
        let qs = AgentQuestions.parse(t)
        #expect(qs.count == 1)
        #expect(qs[0].text == "Не понятно, какой формат нужен. Уточни, пожалуйста.")
        let out = try! AgentQuestions.apply([(qs[0].text, "Любой")], to: t)
        #expect(AgentQuestions.parse(out)[0].answer == "Любой")
        #expect(out.contains("\n\n## Заметки"))
    }

    @Test func codeBlocksAndMissingSection() {
        let t = """
        ## Вопросы
        1. Что делать?
        ```
        2. не вопрос
        ## Вопросы
        ```
        """
        #expect(AgentQuestions.parse(t).map(\.text) == ["Что делать?"])
        #expect(AgentQuestions.parse("Описание\n\n## Заметки\n- x").isEmpty)
        #expect(AgentQuestions.parse("```\n## Вопросы\n1. a\n```").isEmpty)
    }

    @Test func writeChangesOnlyAnswerLines() throws {
        let out = try AgentQuestions.apply([("Нужен ли кеш?", "Да")], to: strict)
        let a = strict.components(separatedBy: "\n"), b = out.components(separatedBy: "\n")
        #expect(b.count == a.count + 1)
        #expect(b.filter { !a.contains($0) } == ["   Ответ: Да"])
        #expect(AgentQuestions.parse(out)[1].answer == "Да")
    }

    @Test func repeatedAnswerReplacesPrevious() throws {
        let out = try AgentQuestions.apply([("Как агент входит в аккаунт?", "Вход внутри контейнера")], to: strict)
        #expect(out.components(separatedBy: "\n").count == strict.components(separatedBy: "\n").count)
        #expect(out.contains("   Ответ: Вход внутри контейнера"))
        #expect(!out.contains("Ответ: Токен в Keychain"))
    }

    @Test func missingQuestionFailsWithoutWriting() {
        #expect(throws: AgentQuestions.WriteError.questionGone("Исчез?")) {
            try AgentQuestions.apply([("Нужен ли кеш?", "Да"), ("Исчез?", "x")], to: strict)
        }
        #expect(throws: AgentQuestions.WriteError.questionGone("a")) {
            try AgentQuestions.apply([("a", "b")], to: "нет раздела")
        }
    }

    @Test func multilineAnswerBecomesOneLine() throws {
        let out = try AgentQuestions.apply([("Нужен ли кеш?", "Да,\n  но\n\nнедолго")], to: strict)
        #expect(out.contains("   Ответ: Да, но недолго"))
        let qs = AgentQuestions.parse(out)
        #expect(qs.count == 2 && qs[1].answer == "Да, но недолго")
    }

    @Test func decideYourselfAndReplyText() throws {
        let out = try AgentQuestions.apply([("Нужен ли кеш?", AgentQuestions.decideYourself)], to: strict)
        #expect(out.contains("Ответ: реши сам"))
        let r = AgentQuestions.replyText([("Нужен ли кеш?", "реши сам"), ("A?", "Да")])
        #expect(r.contains("1. Нужен ли кеш? — реши сам"))
        #expect(r.contains("2. A? — Да"))
    }

    @Test func crlfAndEmptyAnswerAndTabs() throws {
        let crlf = "## Вопросы\r\n1. Нужен ли кеш?\r\n   - Да (рекомендую) пожалуй\r\n   Ответ:\r\n"
        let q = AgentQuestions.parse(crlf)
        #expect(q.count == 1 && q[0].isOpen)
        #expect(q[0].options[0].text == "Да пожалуй")
        let out = try AgentQuestions.apply([("Нужен ли кеш?", "Да")], to: crlf)
        #expect(out == "## Вопросы\r\n1. Нужен ли кеш?\r\n   - Да (рекомендую) пожалуй\r\n   Ответ: Да\r\n")
        let tabs = "## Вопросы\n1. Q?\n\t- A\n"
        #expect(try AgentQuestions.apply([("Q?", "A")], to: tabs) == "## Вопросы\n1. Q?\n\t- A\n\tОтвет: A\n")
    }

    @Test func hashLineDoesNotEndSection() {
        let t = "## Вопросы\n1. Что с #123?\n#456 тоже\n2. Ещё?\n"
        #expect(AgentQuestions.parse(t).count == 2)
    }
}
