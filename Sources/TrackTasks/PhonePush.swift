import Foundation
import SwiftUI
import TrackTasksCore

/// Секреты push (топик ntfy, токены) — только в Keychain, не в UserDefaults и не в логах.
enum PushKeychain {
    static let service = "TrackTasks.push"
    enum Account: String { case ntfyTopic, ntfyToken, pushoverApp, pushoverUser }

    static func get(_ a: Account) -> String { Keychain.get(service: service, account: a.rawValue) }

    /// Пустое значение удаляет запись.
    static func set(_ a: Account, _ value: String) -> Bool { Keychain.set(service: service, account: a.rawValue, value) }
}

enum PhonePush {
    static let enabledKey = "pushEnabled"          // по умолчанию выключено
    static let serviceKey = "pushService"
    static let serverKey = "pushNtfyServer"
    static let detailKey = "pushDetail"
    static let quietKey = "pushQuiet"
    static let quietStartKey = "pushQuietStart"    // минуты от полуночи
    static let quietEndKey = "pushQuietEnd"
    static let permissionKey = "pushOnPermission"
    static let doneKey = "pushOnDone"
    static let failedKey = "pushOnFailed"
    static let lastFailureKey = "pushLastFailure"  // время неудачной отправки, 0 — последняя прошла

    private static var d: UserDefaults { .standard }
    static var enabled: Bool { d.bool(forKey: enabledKey) }
    static var service: PushService { PushService(rawValue: d.string(forKey: serviceKey) ?? "") ?? .ntfy }
    static var detail: PushDetail { PushDetail(rawValue: d.string(forKey: detailKey) ?? "") ?? .brief }

    static func eventOn(_ e: PushEvent) -> Bool {
        let key: String
        switch e { case .permission: key = permissionKey; case .done: key = doneKey; case .failed: key = failedKey }
        return d.object(forKey: key) as? Bool ?? true
    }

    static func request(_ m: PushMessage) -> URLRequest? {
        switch service {
        case .ntfy:
            let token = PushKeychain.get(.ntfyToken)
            return PushRequestBuilder.ntfy(server: d.string(forKey: serverKey) ?? "", topic: PushKeychain.get(.ntfyTopic),
                                           token: token.isEmpty ? nil : token, message: m)
        case .pushover:
            return PushRequestBuilder.pushover(appToken: PushKeychain.get(.pushoverApp), userKey: PushKeychain.get(.pushoverUser), message: m)
        }
    }

    /// Событие очереди → push, если включено, настроено, событие выбрано и не тихие часы.
    static func send(_ e: PushEvent, job: Job, verifyFailed: Bool = false, wait: PushWait? = nil) {
        guard enabled, eventOn(e) else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        guard PushPolicy.shouldSend(enabled: true, quietEnabled: d.bool(forKey: quietKey), minute: minute,
                                    start: d.object(forKey: quietStartKey) as? Int ?? 22 * 60,
                                    end: d.object(forKey: quietEndKey) as? Int ?? 8 * 60) else { return }
        let m = PushPolicy.message(e, detail: detail, project: job.projectName, task: job.title, verifyFailed: verifyFailed,
                                  wait: wait, link: .openTask(job.id))
        guard let r = request(m) else { return }
        Task.detached { _ = await deliver(r) }
    }

    /// Тест из настроек: отправляет всегда (пользователь нажал кнопку), текст — фиксированный.
    static func test() async -> String {
        guard let r = request(PushMessage(title: "TrackTasks", body: "Тестовое уведомление")) else { return "Не заполнены поля сервиса" }
        return await deliver(r) ? "Отправлено" : "Не удалось отправить"
    }

    private static func deliver(_ r: URLRequest) async -> Bool {
        let ok = await perform(r)
        // Только время: ни URL, ни текст ошибки не сохраняются.
        UserDefaults.standard.set(ok ? 0 : Date().timeIntervalSince1970, forKey: lastFailureKey)
        return ok
    }

    private static func perform(_ r: URLRequest) async -> Bool {
        do {
            let (_, resp) = try await URLSession.shared.data(for: r)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false   // ошибку не логируем: в ней может быть URL с топиком
        }
    }
}

struct PhonePushSection: View {
    @AppStorage(PhonePush.enabledKey) private var enabled = false
    @AppStorage(PhonePush.serviceKey) private var service = PushService.ntfy.rawValue
    @AppStorage(PhonePush.serverKey) private var server = ""
    @AppStorage(PhonePush.detailKey) private var detail = PushDetail.brief.rawValue
    @AppStorage(PhonePush.quietKey) private var quiet = false
    @AppStorage(PhonePush.quietStartKey) private var quietStart = 22 * 60
    @AppStorage(PhonePush.quietEndKey) private var quietEnd = 8 * 60
    @AppStorage(PhonePush.permissionKey) private var onPermission = true
    @AppStorage(PhonePush.doneKey) private var onDone = true
    @AppStorage(PhonePush.failedKey) private var onFailed = true
    @AppStorage(PhonePush.lastFailureKey) private var lastFailure = 0.0
    @State private var topic = SecretDraft(.ntfyTopic)
    @State private var ntfyToken = SecretDraft(.ntfyToken)
    @State private var poApp = SecretDraft(.pushoverApp)
    @State private var poUser = SecretDraft(.pushoverUser)
    @State private var testResult: String?

    var body: some View {
        Section("Уведомления на телефон") {
            Toggle("Отправлять push (ntfy / Pushover)", isOn: $enabled)
            Text("Выключено по умолчанию. Текст уходит внешнему сервису. Секреты хранятся в Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            if enabled {
                Picker("Сервис", selection: $service) {
                    Text("ntfy").tag(PushService.ntfy.rawValue)
                    Text("Pushover").tag(PushService.pushover.rawValue)
                }.pickerStyle(.segmented)
                if service == PushService.ntfy.rawValue {
                    TextField("Сервер (пусто = https://ntfy.sh)", text: $server)
                    if !PushRequestBuilder.serverAllowed(server) {
                        Text("Нужен адрес https:// (http — только для localhost), иначе push не отправляется.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    SecretField(title: "Топик (держи в секрете)", draft: $topic)
                    SecretField(title: "Токен доступа (необязательно)", draft: $ntfyToken)
                } else {
                    SecretField(title: "Application token", draft: $poApp)
                    SecretField(title: "User key", draft: $poUser)
                }
                Toggle("Агент ждёт разрешения или одобрения плана", isOn: $onPermission)
                Toggle("Задача выполнена", isOn: $onDone)
                Toggle("Ошибка", isOn: $onFailed)
                Picker("Подробность", selection: $detail) {
                    Text("Кратко — без проектов и задач").tag(PushDetail.brief.rawValue)
                    Text("Подробно — проект и название задачи").tag(PushDetail.full.rawValue)
                }
                if detail == PushDetail.full.rawValue {
                    Text("Название задачи уходит внешнему сервису как есть: не пишите в нём код и секреты.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Тихие часы", isOn: $quiet)
                if quiet {
                    HStack {
                        minutePicker("с", $quietStart)
                        minutePicker("до", $quietEnd)
                    }
                }
                HStack {
                    Button("Отправить тест") {
                        // Клик по кнопке на macOS не снимает фокус с поля.
                        topic.save(); ntfyToken.save(); poApp.save(); poUser.save()
                        testResult = "…"
                        Task { testResult = await PhonePush.test() }
                    }
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                }
                if lastFailure > 0 {
                    Text("Последняя отправка не удалась: \(Date(timeIntervalSince1970: lastFailure).formatted(date: .numeric, time: .shortened))")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func minutePicker(_ label: String, _ minutes: Binding<Int>) -> some View {
        DatePicker(label, selection: Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
        ), displayedComponents: .hourAndMinute)
    }
}

/// Набранное значение секрета и то, что уже лежит в Keychain.
private struct SecretDraft {
    let account: PushKeychain.Account
    var text: String
    private var saved: String
    private(set) var failed = false

    init(_ account: PushKeychain.Account) {
        self.account = account
        saved = PushKeychain.get(account)
        text = saved
    }

    mutating func save() {
        guard text != saved else { failed = false; return }
        failed = !PushKeychain.set(account, text)
        if !failed { saved = text }
    }
}

/// Пишет в Keychain по Enter, потере фокуса и закрытию, а не на каждый символ.
private struct SecretField: View {
    let title: String
    @Binding var draft: SecretDraft
    @FocusState private var focused: Bool

    var body: some View {
        SecureField(title, text: $draft.text)
            .focused($focused)
            .onSubmit { draft.save() }
            .onChange(of: focused) { _, f in if !f { draft.save() } }
            .onDisappear { draft.save() }
        if draft.failed {
            Text("Не удалось сохранить в Keychain").font(.caption).foregroundStyle(.red)
        }
    }
}
