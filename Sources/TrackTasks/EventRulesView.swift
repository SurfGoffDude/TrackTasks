import SwiftUI
import TrackTasksCore

/// «События» on the schedules screen: the server, rules, secrets, the permission to queue, journal.
struct EventRulesSection: View {
    @Environment(Store.self) private var store
    @State private var creating = false
    @State private var port = ""

    private var model: EventRules { store.events }

    var body: some View {
        let projects = store.projects.filter { !$0.eventRules.isEmpty }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("События").font(.system(size: 26, weight: .bold, design: .rounded))
                Spacer()
                Button { creating = true } label: { Label("Новое правило", systemImage: "plus") }
                    .buttonStyle(.glass)
                    .disabled(store.projects.isEmpty)
            }
            if let why = model.stopped ?? model.saveError {
                Label("События не принимаются: \(why)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            serverCard
            ForEach(projects) { p in
                VStack(alignment: .leading, spacing: 10) {
                    Button { store.selectedID = p.id } label: { Text(p.displayName).font(.title3.weight(.semibold)) }
                        .buttonStyle(.plain)
                    ForEach(p.eventRules) { r in EventRuleCard(project: p, rule: r) }
                }
            }
        }
        .sheet(isPresented: $creating) { NewEventRuleSheet() }
        .onAppear { port = String(model.port) }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Приём webhook").font(.headline)
                    status.font(.callout)
                }
                Spacer()
                TextField("Порт", text: $port).frame(width: 70).onSubmit(setPort)
                Button("Сменить порт", action: setPort)
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(Int(port).map { !(1024...65535).contains($0) || $0 == model.port } ?? true)
                Toggle("Приём", isOn: Binding(get: { model.server != .off }, set: { model.setServer($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            Text("Только 127.0.0.1: снаружи — через gh webhook forward или свой туннель. События git сервера не требуют.")
                .font(.callout).foregroundStyle(.secondary)
            if let r = model.rejected[nil], !r.isEmpty {
                Text("Запросов на неизвестный адрес: \(r.values.reduce(0, +))").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder private var status: some View {
        switch model.server {
        case .off: Text("выключен").foregroundStyle(.secondary)
        case .starting: Text("запускается").foregroundStyle(.secondary)
        case .on(let p): Text("http://127.0.0.1:\(String(p))").foregroundStyle(.green)
        case .failed(let why): Text("не запущен: \(why)").foregroundStyle(.red)
        }
    }

    private func setPort() {
        guard let p = Int(port), (1024...65535).contains(p), p != model.port else { return }
        model.setPort(p)
    }
}

private struct EventRuleCard: View {
    @Environment(Store.self) private var store
    let project: Project
    let rule: EventRule
    @State private var error: String?
    @State private var asking: EventRule?
    @State private var secret: ShownSecret?
    @State private var renewing = false

    struct ShownSecret: Identifiable { let id = UUID(); let text: String }
    private var model: EventRules { store.events }

    var body: some View {
        let r = rule
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title.isEmpty ? r.fileName : r.title).font(.headline)
                    Text(Self.text(r)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Включено", isOn: Binding(get: { r.enabled }, set: { on in
                    Task {
                        error = await model.setEnabled(r, on)
                        store.reloadProject(project.id)
                    }
                }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(!r.enabled && !r.errors.isEmpty)
            }
            ForEach(r.errors, id: \.self) { e in
                Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if let a = model.address(r) { remote(r, a) }
            if r.queue { permission(r) }
            HStack(spacing: 8) {
                Button("Открыть файл") { store.open(r.url) }
                Text("\(Automation.folder)/\(r.fileName)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let bad = model.rejected[r.id], !bad.isEmpty {
                Text("Отклонено с запуска: " + EventRules.Reject.allCases.compactMap { k in bad[k].map { "\(k.rawValue) \($0)" } }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange)
            }
            journal(r)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .sheet(item: $asking) { shown in AllowEventSheet(project: project, rule: shown) { error = $0 } }
        .sheet(item: $secret) { SecretSheet(secret: $0.text) }
    }

    @ViewBuilder
    private func remote(_ r: EventRule, _ address: String) -> some View {
        HStack(spacing: 8) {
            Text(address).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Button("Копировать адрес") { copy(address) }
            Button(model.secretKnown[r.id] == true ? "Сменить секрет" : "Создать секрет") {
                renewing = true
                Task {
                    switch await model.renewSecret(r) {
                    case .success(let s): secret = ShownSecret(text: s)
                    case .failure(let e): error = e.text
                    }
                    renewing = false
                }
            }
            .disabled(renewing)
            if r.isActive, model.secretKnown[r.id] == false {
                Text("секрета нет").font(.caption).foregroundStyle(.orange)
                Button("Прочитать снова") { model.loadSecret(r, again: true) }
            }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }

    @ViewBuilder
    private func permission(_ r: EventRule) -> some View {
        HStack(spacing: 8) {
            if model.state.mayQueue(r) {
                Label("Ставит задачу в очередь", systemImage: "checkmark.shield").foregroundStyle(.green)
                Button("Отозвать") { error = model.forbidQueue(r) }
            } else {
                Label(model.state.entries[r.id]?.allowed == nil
                      ? "Просит ставить задачу в очередь: не разрешено, создаёт только черновик"
                      : "Файл изменился: разрешение очереди снято", systemImage: "hand.raised")
                    .foregroundStyle(.orange)
                Button("Разрешить…") { asking = r }.disabled(!r.errors.isEmpty)
            }
        }
        .font(.callout)
        .buttonStyle(.glass)
        .controlSize(.small)
    }

    @ViewBuilder
    private func journal(_ r: EventRule) -> some View {
        let list = Array((model.state.entries[r.id]?.history ?? []).reversed())
        if !list.isEmpty {
            DisclosureGroup("Журнал: \(list.count)") {
                VStack(alignment: .leading, spacing: 4) { ForEach(list) { row($0) } }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
    }

    private func row(_ r: EventState.Record) -> some View {
        HStack(spacing: 8) {
            Text(r.at.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month().hour().minute()))
                .monospacedDigit().foregroundStyle(.secondary)
            switch r.outcome {
            case .started: Text("прервано").foregroundStyle(.orange)
            case .draft: Text("черновик").foregroundStyle(.secondary)
            case .created: Text("задача создана").foregroundStyle(.green)
            case .queued: Text("в очереди").foregroundStyle(.green)
            case .failed: Text("ошибка").foregroundStyle(.red)
            }
            if !r.note.isEmpty { Text(r.note).foregroundStyle(.secondary).lineLimit(2).help(r.note) }
            if let name = r.task {
                if let t = project.task(path: name) {
                    Button(t.title) { store.reveal(t, in: project) }.buttonStyle(.link).lineLimit(1)
                } else {
                    Text(name).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .font(.caption)
    }

    static func text(_ r: EventRule) -> String {
        let what = switch r.kind {
        case .webhook: "webhook"
        case .github: "GitHub: " + r.events.joined(separator: ", ")
        case .git: "новые коммиты"
        case nil: "событие не задано"
        }
        return what + (r.branches.isEmpty ? "" : " · ветки " + r.branches.joined(separator: ", ")) + " · не чаще \(r.limit) в час"
    }
}

@MainActor private func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// The only time the secret is shown.
private struct SecretSheet: View {
    @Environment(\.dismiss) private var dismiss
    let secret: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Секрет правила").font(.title3.bold())
            Text(secret).font(.callout.monospaced()).textSelection(.enabled)
            Text("Показывается один раз, хранится в Keychain. Прежний секрет больше не действует.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Копировать") { copy(secret) }
                Spacer()
                Button("Готово") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

private struct AllowEventSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let rule: EventRule
    let done: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ставить в очередь без вопроса?").font(.title3.bold())
            Text("\(project.displayName) · \(rule.title) · \(EventRuleCard.text(rule))"
                 + (rule.agent.isEmpty ? "" : " · агент \(rule.agent)")
                 + (rule.size.isEmpty ? "" : " · размер \(rule.size)")
                 + (rule.fields.isEmpty ? "" : " · поля " + rule.fields.joined(separator: ", ")))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(rule.body.isEmpty ? "(пустой текст)" : rule.body)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 240)
            .padding(8)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            Label("Агент прочитает и данные события — чужой текст, в котором могут быть вредные указания. Пометка «данные» — не защита.",
                  systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            Text("Опасный режим и автослияние на такие задачи не действуют. Любая правка файла, кроме enabled, снимет разрешение.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Разрешить") {
                    done(store.events.allowQueue(rule))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

private struct NewEventRuleSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var creating = false
    @State private var projectID = ""
    @State private var kind = EventRule.Kind.webhook
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Новое правило события").font(.title3.bold())
            Picker("Проект", selection: $projectID) {
                ForEach(store.projects.sorted { $0.displayName < $1.displayName }) { Text($0.displayName).tag($0.id) }
            }
            Picker("Событие", selection: $kind) {
                Text("Webhook").tag(EventRule.Kind.webhook)
                Text("GitHub").tag(EventRule.Kind.github)
                Text("Коммиты git").tag(EventRule.Kind.git)
            }
            TextField("Название", text: $title)
            Text("Файл создаётся выключенным: условия и текст задачи правятся в нём.").font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Создать") {
                    guard let p = store.project(projectID) else { return }
                    creating = true
                    Task {
                        error = await store.events.create(title: title.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, in: p)
                        creating = false
                        store.reloadProject(p.id)
                        if error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(creating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.project(projectID) == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { projectID = store.projects.min { $0.displayName < $1.displayName }?.id ?? "" }
    }
}
