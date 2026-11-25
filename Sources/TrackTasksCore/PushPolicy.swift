import Foundation

/// Событие, о котором можно отправить push на телефон.
public enum PushEvent: String, Sendable, CaseIterable {
    case permission   // агент ждёт разрешения или одобрения
    case done         // задача выполнена
    case failed       // ошибка
}

/// Сколько данных уходит внешнему сервису.
public enum PushDetail: String, Sendable, CaseIterable {
    case brief   // без названий проектов, задач и кода
    case full    // проект и задача в тексте
}

/// Чего ждёт агент (только для полного режима).
public enum PushWait: String, Sendable, CaseIterable {
    case permission   // разрешение на команду
    case plan         // одобрение плана
    case question     // вопрос агента
    case redCheck     // проверка verify не прошла
}

public struct PushMessage: Equatable, Sendable {
    public var title: String
    public var body: String
    /// Ссылка, открывающая задачу на Mac. Только в полном режиме.
    public var link: String?
    public init(title: String, body: String, link: String? = nil) { self.title = title; self.body = body; self.link = link }
}

/// Ссылка приложения `tracktasks://task/<id задачи в очереди>`. Умеет только открыть задачу:
/// других действий (одобрить, запустить, слить) в схеме нет, лишние части адреса отвергаются.
public enum AppLink: Equatable, Sendable {
    case openTask(UUID)

    public static let scheme = "tracktasks"

    public var url: String {
        switch self { case .openTask(let id): return "\(Self.scheme)://task/\(id.uuidString)" }
    }

    public static func parse(_ url: URL) -> AppLink? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == "task",
              url.query == nil, url.fragment == nil, url.user == nil, url.port == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let id = UUID(uuidString: parts[0]) else { return nil }
        return .openTask(id)
    }
}

public enum PushPolicy {
    /// Текст push. В кратком режиме — только фиксированные фразы: ни проекта, ни задачи, ни вывода агента.
    public static func message(_ event: PushEvent, detail: PushDetail, project: String, task: String, verifyFailed: Bool = false,
                               wait: PushWait? = nil, link: AppLink? = nil) -> PushMessage {
        let title: String
        switch event {
        case .permission: title = "Агент ждёт ответа"
        case .done: title = verifyFailed ? "Готово, проверка не прошла" : "Задача выполнена"
        case .failed: title = "Задача не выполнена"
        }
        switch detail {
        case .brief: return PushMessage(title: title, body: "TrackTasks")
        case .full:
            var kind = wait
            if event == .done, verifyFailed { kind = .redCheck }
            let body = "\(project): \(task)" + (kind.map { " — " + waitText($0) } ?? "")
            return PushMessage(title: title, body: body, link: link?.url)
        }
    }

    /// Фиксированные фразы: текст агента и команд сюда не попадает.
    public static func waitText(_ w: PushWait) -> String {
        switch w {
        case .permission: return "нужно разрешение"
        case .plan: return "план ждёт одобрения"
        case .question: return "агент задал вопрос"
        case .redCheck: return "проверка не прошла"
        }
    }

    /// Тихие часы в минутах от полуночи; интервал может переходить через полночь (22:00–08:00).
    public static func isQuiet(minute: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }
        return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }

    /// Отправлять ли push: включено и не тихие часы.
    public static func shouldSend(enabled: Bool, quietEnabled: Bool, minute: Int, start: Int, end: Int) -> Bool {
        guard enabled else { return false }
        return !(quietEnabled && isQuiet(minute: minute, start: start, end: end))
    }
}

public enum PushService: String, Sendable, CaseIterable {
    case ntfy, pushover
}

public enum PushRequestBuilder {
    /// Только https; http — лишь для этого же компьютера, иначе топик и токен уйдут открытым текстом.
    public static func serverAllowed(_ server: String) -> Bool {
        let s = server.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return true }   // пусто = https://ntfy.sh
        guard let url = URL(string: s) else { return false }
        return allowed(url)
    }

    private static func allowed(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        default: return false
        }
    }

    /// ntfy: POST <сервер>/<топик>, тело — текст, заголовок Title; токен — Bearer.
    public static func ntfy(server: String, topic: String, token: String?, message: PushMessage) -> URLRequest? {
        var base = server.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "https://ntfy.sh" }
        while base.hasSuffix("/") { base.removeLast() }
        let t = topic.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let url = URL(string: base + "/" + t), allowed(url) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.httpBody = Data(message.body.utf8)
        // Заголовки HTTP — ASCII, поэтому заголовок кодируется по RFC 2047.
        r.setValue("=?UTF-8?B?" + Data(message.title.utf8).base64EncodedString() + "?=", forHTTPHeaderField: "Title")
        if let token, !token.isEmpty { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let link = message.link { r.setValue(link, forHTTPHeaderField: "Click") }
        return r
    }

    /// Pushover: POST https://api.pushover.net/1/messages.json (form).
    public static func pushover(appToken: String, userKey: String, message: PushMessage) -> URLRequest? {
        guard !appToken.isEmpty, !userKey.isEmpty, let url = URL(string: "https://api.pushover.net/1/messages.json") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let form = ([("token", appToken), ("user", userKey), ("title", message.title), ("message", message.body)]
            + (message.link.map { [("url", $0)] } ?? []))
            .map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&")
        r.httpBody = Data(form.utf8)
        return r
    }
}
