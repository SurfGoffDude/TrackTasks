import Observation
import SwiftUI
import TrackTasksCore

/// Settings → «Docker»: what containers are made from. Until all of it is there, `executor: docker` is refused.
@MainActor @Observable
final class DockerSetup {
    static let shared = DockerSetup()

    nonisolated static let service = "TrackTasks.docker", account = "claude-oauth-token"
    private enum Key { static let on = "dockerEnabled", image = "dockerImage", memory = "dockerMemoryMB", cpus = "dockerCPUs", domains = "dockerDomains" }

    @ObservationIgnored private let d: UserDefaults
    var enabled: Bool { didSet { d.set(enabled, forKey: Key.on); apply() } }
    /// Empty = the app's own image.
    var image: String { didSet { d.set(image, forKey: Key.image); apply() } }
    var memoryMB: Int { didSet { d.set(memoryMB, forKey: Key.memory); apply() } }
    var cpus: Int { didSet { d.set(cpus, forKey: Key.cpus); apply() } }
    var domains: String { didSet { d.set(domains, forKey: Key.domains); apply() } }
    private(set) var hasToken: Bool

    init(_ d: UserDefaults = .standard, hasToken: Bool? = nil) {
        self.d = d
        enabled = d.bool(forKey: Key.on)
        image = d.string(forKey: Key.image) ?? ""
        memoryMB = d.object(forKey: Key.memory) as? Int ?? 4096
        cpus = d.object(forKey: Key.cpus) as? Int ?? 2
        domains = d.string(forKey: Key.domains) ?? DockerProxy.defaultDomains.joined(separator: " ")
        self.hasToken = hasToken ?? Keychain.exists(service: Self.service, account: Self.account)
    }

    /// For project commands in marked folders: they need no sign-in.
    func apply() { ContainerStore.shared.host = base }

    private var base: DockerHost? {
        guard enabled, let engine = DockerEngine.find(), let names = DockerProxy.parse(domains) else { return nil }
        let own = image.trimmingCharacters(in: .whitespaces)
        var h = DockerHost(engine: engine, image: own.isEmpty ? DockerImage.tag : own)
        h.limits.memoryMB = memoryMB
        h.limits.cpus = Double(cpus)
        // Always the app's image: a project's own one must not decide where the agent may go.
        h.proxy = DockerProxy(image: DockerImage.tag, domains: names)
        return h
    }

    /// For the queue. The image is checked at the start of a job, off the main thread.
    var host: DockerHost? {
        guard hasToken, var h = base else { return nil }
        h.token = { Keychain.get(service: Self.service, account: Self.account) }
        return h
    }

    func setToken(_ value: String) -> Bool {
        guard Keychain.set(service: Self.service, account: Self.account, value) else { return false }
        hasToken = !value.isEmpty
        return true
    }

    /// Downloads the base image and packages: only by the button.
    nonisolated static func build() -> String? {
        guard let e = DockerEngine.find() else { return "Docker не найден" }
        let r = e.run(["build", "-t", DockerImage.tag, "-"], timeout: 20 * 60, input: DockerImage.dockerfile)
        return r.ok ? nil : String((r.out + r.err).suffix(600))
    }

    nonisolated static func state() -> String {
        guard let e = DockerEngine.find() else { return "Docker не найден" }
        guard e.isUp else { return "Docker не запущен" }
        return e.hasImage(DockerImage.tag) ? "Образ готов: \(DockerImage.tag)" : "Образ не собран"
    }
}

struct DockerSettingsSection: View {
    @Bindable private var setup = DockerSetup.shared
    @State private var token = ""
    @State private var state = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        Section("Docker") {
            Toggle("Разрешить запуск в контейнере", isOn: $setup.enabled)
            Text("Для проектов и задач с executor: docker: Claude, setup и verify видят только worktree задачи. Действует только для Claude.")
                .font(.caption).foregroundStyle(.secondary)
            if setup.enabled {
                HStack {
                    Text(state.isEmpty ? "Проверяю Docker…" : state).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button(busy ? "Собираю…" : "Собрать образ", action: build).disabled(busy)
                        .help("Скачает node, git, ripgrep и Claude Code \(DockerImage.claudeVersion)")
                }
                .task { state = await Task.detached { DockerSetup.state() }.value }
                HStack {
                    SecureField("Токен Claude", text: $token, prompt: Text(setup.hasToken ? "сохранён в Keychain" : "вывод claude setup-token"))
                    Button("Сохранить") { save(token) }.disabled(token.isEmpty)
                    if setup.hasToken { Button("Удалить", role: .destructive) { save("") } }
                }
                Text("Выполни в терминале claude setup-token и вставь результат. Агент в контейнере может прочитать этот токен; он виден и в docker inspect, пока контейнер есть.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Разрешённые домены", text: $setup.domains)
                if DockerProxy.parse(setup.domains) == nil {
                    Text("Только имена доменов через пробел; точка в начале — все поддомены. Пока список неверен, контейнеры не запускаются.")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Агент и setup выходят в сеть только к ним, по https. Для npm install в setup добавь registry.npmjs.org. Каждый домен — путь, которым агент может отправить код. verify идёт без сети.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper("Память: \(setup.memoryMB) МБ", value: $setup.memoryMB, in: 1024...32768, step: 1024)
                Stepper("Процессоры: \(setup.cpus)", value: $setup.cpus, in: 1...16)
                TextField("Свой образ (пусто = образ приложения)", text: $setup.image)
                Text("Свой образ должен уже быть в Docker, с claude и папкой \(ContainerSpec.sessionsDir) с правами 1777. Прокси всегда работает из образа приложения.")
                    .font(.caption).foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
    }

    private func save(_ value: String) {
        let ok = setup.setToken(value.trimmingCharacters(in: .whitespacesAndNewlines))
        error = ok ? "" : "Keychain не записал токен"
        if ok { token = "" }
    }

    private func build() {
        busy = true
        error = ""
        Task {
            let (why, now) = await Task.detached { (DockerSetup.build(), DockerSetup.state()) }.value
            busy = false
            error = why ?? ""
            state = now
        }
    }
}
