import SwiftUI
import TrackTasksCore

/// Settings: connections to the trackers issues are imported from.
struct IssueSourcesSection: View {
    var body: some View {
        Section("Импорт из трекеров") {
            Text("Только чтение. Токены хранятся в Keychain; команда или проект выбираются в окне импорта. GitHub работает через gh, настраивать его здесь не нужно.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(IssueSourceID.withToken, id: \.self) { IssueSourceRow(id: $0) }
        }
    }
}

private struct IssueSourceRow: View {
    let id: IssueSourceID
    @AppStorage private var enabled: Bool
    @AppStorage private var address: String
    @AppStorage private var email: String
    @AppStorage private var organization: String
    /// Typed token, never the saved one.
    @State private var draft = ""
    @State private var saved = false
    @State private var busy = false
    @State private var result = ""

    init(id: IssueSourceID) {
        self.id = id
        _enabled = AppStorage(wrappedValue: false, IssueSourceStore.enabledKey(id))
        _address = AppStorage(wrappedValue: "", IssueSourceStore.addressKey(id))
        _email = AppStorage(wrappedValue: "", IssueSourceStore.emailKey(id))
        _organization = AppStorage(wrappedValue: "", IssueSourceStore.organizationKey(id))
    }

    var body: some View {
        Toggle(id.name, isOn: $enabled)
        if enabled {
            if id != .linear {
                TextField(addressTitle, text: $address)
                if badAddress {
                    Text("Нужен адрес https:// (http — только для localhost).").font(.caption).foregroundStyle(.red)
                }
            }
            if id == .jira { TextField("Email учётной записи", text: $email) }
            if id == .sentry { TextField("Организация (slug)", text: $organization) }
            SecureField(saved ? "Токен сохранён — введите новый, чтобы заменить" : "Токен", text: $draft)
                .onSubmit { save(check: false) }
            Text(hint).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Сохранить токен") { save(check: false) }.disabled(draft.isEmpty || busy)
                Button("Проверить доступ") { save(check: true) }.disabled(busy || (draft.isEmpty && !saved))
                Button("Удалить токен", role: .destructive) { remove() }.disabled(busy || !saved)
                if busy { ProgressView().controlSize(.small) }
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
            .task(id: address) {
                result = ""
                await refresh()
            }
        }
    }

    private var badAddress: Bool { !address.isEmpty && IssueConnection.base(id, address: address) == nil }

    private var addressTitle: String {
        switch id {
        case .jira: "Адрес (https://company.atlassian.net)"
        case .gitlab: "Адрес (пусто = https://gitlab.com)"
        default: "Адрес (пусто = https://sentry.io; для ЕС — https://de.sentry.io)"
        }
    }

    private var hint: String {
        switch id {
        case .linear: "Personal API key с правом Read (Settings → Security & access)."
        case .jira: "API token без scopes (id.atlassian.com → Security). Только Jira Cloud. Права токена — права учётной записи."
        case .gitlab: "Access token с правом read_api."
        default: "Токен с правом event:read. Читаются заголовок, место и уровень ошибки, события — нет."
        }
    }

    private func refresh() async {
        let id = id, address = address
        let has = await Task.detached { IssueSourceStore.hasToken(id, address: address) }.value
        if address == self.address { saved = has }
    }

    private func save(check: Bool) {
        let id = id, address = address, token = draft
        guard !token.isEmpty || check else { return }
        busy = true
        result = ""
        Task {
            var text = ""
            var ok = true
            if !token.isEmpty {
                ok = await Task.detached { IssueSourceStore.saveToken(id, address: address, token) }.value
                if ok { if draft == token { draft = "" } } else { text = "Не сохранено: проверьте адрес и доступ к Keychain" }
                await refresh()
            }
            if ok, check {
                // The check needs no team or project.
                let r = await Task.detached { () -> Result<Bool, IssueSourceError> in
                    guard let s = IssueSourceStore.connection(id).source(id, scope: "") else { return .failure(.badRequest) }
                    return await IssueLoader.check(s)
                }.value
                switch r {
                case .success: text = "Доступ есть"
                case .failure(let e): text = e.message
                }
            }
            result = text
            busy = false
        }
    }

    private func remove() {
        let id = id, address = address
        busy = true
        Task {
            let ok = await Task.detached { IssueSourceStore.saveToken(id, address: address, "") }.value
            await refresh()
            result = ok ? "Токен удалён" : "Не удалось удалить токен"
            busy = false
        }
    }
}
