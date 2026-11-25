import Testing
@testable import TrackTasksCore

@Suite struct ChatIntentTests {
    @Test(arguments: [
        "добавь кнопку в настройки", "Сделай экспорт в CSV", "Исправь баг с датами", "пожалуйста, удали старые логи",
        "нужно добавить фильтр по вехам", "надо починить сборку", "давай добавим тёмную тему", "Теперь перепиши парсер",
        "можешь добавить кнопку?", "Could you fix the build?", "Add a button to settings", "fix the crash on launch",
        "we need to rename the module", "Please update the README", "хочу чтобы список сортировался по дате",
        "Реализовать поиск по задачам",
    ])
    func requests(_ text: String) {
        #expect(ChatIntent.isRequest(text))
    }

    @Test(arguments: [
        "почему падает сборка?", "как работает очередь", "что делает QueueServer", "нужно ли добавлять depends?",
        "Объясни, как устроен WavePlan", "добавить можно?", "How does the queue work?", "what does this do",
        "", "   ", "/help", "привет", "спасибо, понятно", "расскажи про архитектуру", "хочу понять, как это работает",
        "сделано", "это добавлено вчера", "Why did the build fail", "can you explain this?",
    ])
    func notRequests(_ text: String) {
        #expect(!ChatIntent.isRequest(text))
    }

    @Test func longPastedTextIsNotAsked() {
        #expect(!ChatIntent.isRequest("исправь " + String(repeating: "лог ", count: 300)))
    }

    @Test func yoIsNormalised() {
        #expect(ChatIntent.isRequest("Перенеси это в Core"))
        #expect(ChatIntent.isRequest("давай уберём дубли"))
    }
}
