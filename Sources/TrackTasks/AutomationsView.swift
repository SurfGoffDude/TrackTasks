import SwiftUI
import TrackTasksCore

/// «Расписания»: schedules of all projects, the switch, the permission to queue, history.
struct AutomationsView: View {
    @Environment(Store.self) private var store
    @State private var creating = false

    var body: some View {
        let projects = store.projects.filter { !$0.automations.isEmpty }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Расписания").font(.system(size: 32, weight: .bold, design: .rounded))
                    Spacer()
                    Button { creating = true } label: { Label("Новое", systemImage: "plus") }
                        .buttonStyle(.glass)
                        .disabled(store.projects.isEmpty)
                }
                if let why = store.automations.stopped ?? store.automations.saveError {
                    Label("Автозапуски стоят: \(why)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text("Работают, пока приложение открыто. После сна или перерыва выполняется один пропущенный запуск.")
                    .font(.callout).foregroundStyle(.secondary)
                if projects.isEmpty {
                    ContentUnavailableView("Расписаний нет", systemImage: "calendar.badge.clock",
                                           description: Text("Файлы automations/*.md в проектах."))
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
                ForEach(projects) { p in
                    VStack(alignment: .leading, spacing: 10) {
                        Button { store.selectedID = p.id } label: { Text(p.displayName).font(.title3.weight(.semibold)) }
                            .buttonStyle(.plain)
                        ForEach(p.automations) { a in AutomationCard(project: p, automation: a) }
                    }
                }
                EventRulesSection()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Backdrop())
        .sheet(isPresented: $creating) { NewAutomationSheet() }
    }
}

private struct AutomationCard: View {
    @Environment(Store.self) private var store
    let project: Project
    let automation: Automation
    @State private var error: String?
    @State private var asking: Automation?

    private var model: Automations { store.automations }

    var body: some View {
        let a = automation
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title.isEmpty ? a.fileName : a.title).font(.headline)
                    Text(a.rule.map(Self.text) ?? "расписание не задано").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let next = model.next(a) {
                    Text("Следующий: " + next.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month().weekday().hour().minute()))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Toggle("Включено", isOn: Binding(get: { a.enabled }, set: { on in
                    Task {
                        error = await model.setEnabled(a, on)
                        store.reloadProject(project.id)
                    }
                }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(!a.enabled && !a.errors.isEmpty)
            }
            ForEach(a.errors, id: \.self) { e in
                Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if a.queue { permission(a) }
            HStack(spacing: 8) {
                Button("Запустить сейчас") {
                    Task { error = await model.run(a, in: project, manual: true) }
                }
                .disabled(!a.errors.isEmpty || model.running.contains(a.id))
                Button("Открыть файл") { store.open(a.url) }
                Text("\(Automation.folder)/\(a.fileName)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            history(a)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .sheet(item: $asking) { shown in
            AllowQueueSheet(project: project, automation: shown) { error = $0 }
        }
    }

    @ViewBuilder
    private func permission(_ a: Automation) -> some View {
        HStack(spacing: 8) {
            if model.state.mayQueue(a) {
                Label("Ставит задачу в очередь", systemImage: "checkmark.shield").foregroundStyle(.green)
                Button("Отозвать") { error = model.forbidQueue(a) }
            } else {
                Label(model.state.entries[a.id]?.allowed == nil
                      ? "Просит ставить задачу в очередь: не разрешено, только создаёт задачу"
                      : "Файл изменился: разрешение очереди снято", systemImage: "hand.raised")
                    .foregroundStyle(.orange)
                Button("Разрешить…") { asking = a }.disabled(!a.errors.isEmpty)
            }
        }
        .font(.callout)
        .buttonStyle(.glass)
        .controlSize(.small)
    }

    @ViewBuilder
    private func history(_ a: Automation) -> some View {
        let runs = Array((model.state.entries[a.id]?.history ?? []).reversed())
        if !runs.isEmpty {
            DisclosureGroup("История: \(runs.count)") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(runs) { r in row(r, active: model.running.contains(a.id) && r.id == runs[0].id) }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
    }

    private func row(_ r: AutomationState.Run, active: Bool) -> some View {
        HStack(spacing: 8) {
            Text(r.at.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month().hour().minute()))
                .monospacedDigit().foregroundStyle(.secondary)
            if r.slot == nil { Text("вручную").foregroundStyle(.tertiary) }
            Text(Self.title(r.outcome, active: active)).foregroundStyle(Self.color(r.outcome))
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

    static func title(_ o: AutomationState.Run.Outcome, active: Bool) -> String {
        switch o {
        case .started: active ? "запускается" : "прервано"
        case .created: "задача создана"
        case .queued: "в очереди"
        case .skipped: "пропущено"
        case .failed: "ошибка"
        }
    }

    static func color(_ o: AutomationState.Run.Outcome) -> Color {
        switch o {
        case .created, .queued: .green
        case .skipped: .secondary
        case .started: .orange
        case .failed: .red
        }
    }

    static func text(_ r: Automation.Rule) -> String {
        let time = String(format: "%02d:%02d", r.hour, r.minute)
        switch r.kind {
        case .daily: return "каждый день в \(time)"
        case .weekly:
            let names = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]
            // Monday first.
            let days = r.weekdays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { names[$0 - 1] }
            return "\(days.joined(separator: ", ")) в \(time)"
        case .monthly: return "\(r.day)-го числа в \(time)"
        }
    }
}

/// The person reads exactly what the agent will be given.
private struct AllowQueueSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let automation: Automation
    let done: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ставить в очередь без вопроса?").font(.title3.bold())
            Text("\(project.displayName) · \(automation.title) · \(automation.rule.map(AutomationCard.text) ?? "")"
                 + (automation.agent.isEmpty ? "" : " · агент \(automation.agent)")
                 + (automation.size.isEmpty ? "" : " · размер \(automation.size)"))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(automation.body.isEmpty ? "(пустой текст)" : automation.body)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 260)
            .padding(8)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            Text("Агент получит этот текст по расписанию. Любая правка файла снимет разрешение. Результат сливает человек, даже при автопилоте.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Разрешить") {
                    done(store.automations.allowQueue(automation))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

private struct NewAutomationSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var creating = false
    @State private var projectID = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Новое расписание").font(.title3.bold())
            Picker("Проект", selection: $projectID) {
                ForEach(store.projects.sorted { $0.displayName < $1.displayName }) { Text($0.displayName).tag($0.id) }
            }
            TextField("Название", text: $title)
            Text("Файл создаётся выключенным: время и текст задачи правятся в нём.").font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Создать") {
                    guard let p = store.project(projectID) else { return }
                    creating = true
                    Task {
                        error = await store.automations.create(title: title.trimmingCharacters(in: .whitespacesAndNewlines), in: p)
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
