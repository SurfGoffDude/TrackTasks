import Foundation

/// Дешёвая эвристика (без LLM): похоже ли сообщение в чат на просьбу выполнить работу.
/// При сомнении отвечает «нет» — лишний вопрос раздражает больше, чем пропущенный.
public enum ChatIntent {
    /// Слова в начале, которые не меняют смысл («пожалуйста, добавь…»).
    static let fillers: Set<String> = [
        "пожалуйста", "плиз", "ну", "а", "и", "тогда", "теперь", "еще", "также", "давай", "давайте",
        "please", "pls", "then", "now", "also", "ok", "ок", "so",
    ]
    /// «Можешь сделать…» — вежливая просьба, вопросительный знак её не отменяет.
    static let politeLeads: [[String]] = [
        ["можешь"], ["можете"], ["сможешь"], ["сможете"],
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
    ]
    static let questionWords: Set<String> = [
        "почему", "как", "что", "зачем", "где", "когда", "какой", "какая", "какие", "какое", "каких",
        "сколько", "кто", "куда", "откуда", "чем", "отчего", "разве", "есть", "ли",
        "why", "how", "what", "where", "when", "which", "who", "whose", "is", "are", "was", "were",
        "does", "do", "did", "can", "could", "should", "would", "will", "explain", "show", "tell",
        "объясни", "расскажи", "покажи", "опиши", "поясни", "скажи", "перечисли",
    ]
    /// Фразы-потребности в начале: «нужно сделать…», «I need …».
    static let needPhrases: [[String]] = [
        ["нужно"], ["надо"], ["необходимо"], ["требуется"], ["хочу", "чтобы"], ["хотим", "чтобы"], ["хотелось", "бы"],
        ["i", "need"], ["we", "need"], ["need", "to"], ["let", "s"], ["lets"],
    ]
    static let verbs: Set<String> = [
        // повелительное и инфинитив
        "сделай", "сделайте", "сделать", "добавь", "добавьте", "добавить", "исправь", "исправьте", "исправить",
        "поправь", "поправить", "почини", "почините", "починить", "пофикси", "зафикси", "создай", "создайте", "создать",
        "удали", "удалите", "удалить", "убери", "уберите", "убрать", "переименуй", "переименовать", "замени", "заменить",
        "измени", "изменить", "поменяй", "поменять", "обнови", "обновить", "напиши", "напишите", "написать",
        "запусти", "запустить", "вынеси", "вынести", "перенеси", "перенести", "реализуй", "реализовать", "внедри",
        "внедрить", "оптимизируй", "оптимизировать", "подключи", "подключить", "отключи", "отключить", "включи",
        "включить", "настрой", "настроить", "поддержи", "поддержать", "перепиши", "переписать", "отрефакторь",
        "рефактори", "разбей", "разбить", "сверстай", "допиши", "дописать", "доработай", "доработать", "выполни",
        "выполнить", "подготовь", "подготовить", "сгенерируй", "сгенерировать", "заверши", "завершить",
        "проверь", "проверить", "собери", "собрать", "перезапиши", "скопируй", "скопировать", "ускорь", "ускорить",
        // первое лицо мн. числа после «давай»
        "сделаем", "добавим", "исправим", "починим", "создадим", "удалим", "уберем", "заменим", "изменим",
        "обновим", "напишем", "реализуем", "перепишем", "вынесем", "перенесем", "подключим", "настроим",
        // English
        "add", "fix", "make", "create", "implement", "remove", "delete", "rename", "update", "change", "write",
        "build", "refactor", "move", "replace", "set", "install", "configure", "enable", "disable", "rewrite",
        "optimize", "extend", "split", "extract", "run", "generate", "finish", "complete", "check", "support",
    ]

    /// Длинный текст — скорее вставленный лог или контекст, чем короткая просьба.
    static let maxLength = 800

    public static func isRequest(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength, !trimmed.hasPrefix("/") else { return false }
        var words = tokens(trimmed)
        while let f = words.first, fillers.contains(f) { words.removeFirst() }
        guard !words.isEmpty else { return false }

        for lead in politeLeads where words.starts(with: lead) {
            var rest = Array(words.dropFirst(lead.count))
            while let f = rest.first, fillers.contains(f) || f == "бы" { rest.removeFirst() }
            return rest.first.map(verbs.contains) ?? false
        }
        if trimmed.contains("?") || trimmed.contains("？") { return false }
        if words.contains("ли") { return false }
        if questionWords.contains(words[0]) { return false }
        // «нужно ли…» уже отсеяно выше
        if needPhrases.contains(where: { words.starts(with: $0) }) { return true }
        return verbs.contains(words[0])
    }

    /// Слова в нижнем регистре, «ё» → «е», знаки препинания — разделители.
    static func tokens(_ s: String) -> [String] {
        let lower = s.lowercased().replacingOccurrences(of: "ё", with: "е")
        return lower.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }
}
