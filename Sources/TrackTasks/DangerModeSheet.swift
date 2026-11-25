import SwiftUI
import TrackTasksCore

/// Turning the mode on: consequences, term and the project's name typed by hand.
struct DangerModeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    var onEnabled: () -> Void = {}
    @State private var typed = ""
    @Environment(Store.self) private var store
    @State private var duration = DangerMode.Duration.hour
    @State private var autopilot = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Опасный режим: \(project.displayName)", systemImage: "exclamationmark.octagon.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            Text("""
            Задачи этого проекта идут в очереди без вопросов до слияния:
            • Claude работает с --dangerously-skip-permissions: любая команда без подтверждения. Он может удалить файлы, выйти за папку проекта, прочитать секреты, выполнить git push.
            • У Codex полного доступа нет: его запросы ждут ответа, полный доступ и автоответ действуют только для Claude.
            • Запросы планирования, ревью и разрешения конфликтов одобряются сами: любые команды и на этих шагах.
            • План одобряется сам (и если другая задача мешала проверить, что код не тронут), замечания ревью исправляются один раз, setup и teardown запускаются, зависимости добавляются.
            • Код пишется в отдельном worktree; незакоммиченное в основной папке трекер не трогает. Worktree — не песочница.

            Без автопилота трекер сам не сливает. Пушить и создавать PR он не будет в любом случае. Задачи с source: (чужой текст) идут с обычными правами. Сам агент с полным доступом может изменить и настройки этого режима.
            """)
            .fixedSize(horizontal: false, vertical: true)
            Picker("Срок", selection: $duration) {
                ForEach(DangerMode.Duration.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Автопилот: сливать готовое в main самому", isOn: $autopilot)
            if autopilot {
                Text("Проверка, ревью, до \(Autopilot.maxFixes) исправлений, проверка вместе со свежим main, слияние. Конфликт и красную проверку чинит агент, до \(Autopilot.maxRepairs) раз; не вышло — ветка откладывается. В main попадёт код, который никто из людей не читал. Проверка: \(project.verify.isEmpty ? "не задана" : project.verify)")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let g = store.git[project.id], g.dirty > 0 {
                HStack {
                    Text("В основной папке незакоммичено: \(g.dirty). Ветки этого не увидят, а с пересечениями не сольются.")
                        .font(.callout).foregroundStyle(.orange)
                    Button("Закоммитить…") { dismiss(); store.commitProject = project }
                }
            }
            TextField("Введи имя проекта: \(project.displayName)", text: $typed)
                .textFieldStyle(.roundedBorder)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Включить", role: .destructive) {
                    if let e = DangerModeStore.shared.enable(project, typed: typed, duration, autopilot: autopilot) { error = e } else { dismiss(); onEnabled() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines)
                          != project.displayName.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

/// Project header: the mode's state and switch.
struct DangerPill: View {
    let project: Project
    @State private var asking = false

    var body: some View {
        // Expiry is also shown without a queue event.
        SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { _ in
            let on = DangerModeStore.shared.isOn(project.url)
            Button {
                if on { DangerModeStore.shared.disable([project.url.path]) } else { asking = true }
            } label: {
                Pill(text: on ? "опасный режим" + DangerText.until(project.url.path) : "опасный режим выключен",
                     color: on ? .red : .secondary, icon: "exclamationmark.octagon")
            }
            .buttonStyle(.plain)
            .help(on ? "Выключить опасный режим. Идущие задачи с полным доступом остановит «Стоп всё» в очереди"
                     : "Очередь без вопросов до слияния, на время")
        }
        .sheet(isPresented: $asking) { DangerModeSheet(project: project) }
    }
}

@MainActor enum DangerText {
    static func until(_ path: String) -> String {
        guard let g = DangerModeStore.shared.grant(path) else { return "" }
        let auto = g.autopilot == true ? " · автопилот" : ""
        guard let u = g.until else { return auto + " · до выключения" }
        return auto + " · до " + u.formatted(date: .omitted, time: .shortened)
    }
}

/// Red bar: where the mode is on, off switches and «Стоп всё».
struct DangerBar: View {
    @Environment(Store.self) private var store
    @State private var confirmStop = false

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { _ in
            let active = DangerModeStore.shared.active
            let running = store.jobs.fullAccessRunning.count
            if !active.isEmpty || running > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(active.isEmpty ? "Опасный режим выключен, но задачи с полным доступом ещё идут: \(running)"
                                             : "Опасный режим: в очереди разрешено всё" + (running > 0 ? " · идёт с полным доступом: \(running)" : ""),
                              systemImage: "exclamationmark.octagon.fill")
                            .font(.headline)
                        Spacer()
                        Button("Стоп всё", role: .destructive) { confirmStop = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .help("Выключить режим везде, поставить очередь на паузу, остановить задачи с полным доступом вместе с их командами")
                    }
                    ForEach(active, id: \.self) { path in
                        HStack {
                            Text(URL(fileURLWithPath: path).lastPathComponent + DangerText.until(path)).font(.callout)
                            Spacer()
                            Button("Выключить") { DangerModeStore.shared.disable([path]) }
                                .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                }
                .foregroundStyle(.red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.15), in: .rect(cornerRadius: 12))
            }
        }
        .confirmationDialog("Остановить всё в опасном режиме?", isPresented: $confirmStop) {
            Button("Стоп всё", role: .destructive) { store.jobs.dangerStopAll() }
        } message: { Text("Режим выключится во всех проектах, очередь встанет на паузу, задачи с полным доступом прервутся.") }
    }
}

/// Once after the update: the old global switch does not carry over.
struct OldAllowAllBanner: View {
    @Environment(Store.self) private var store
    @State private var enabling: Project?

    var body: some View {
        if DangerModeStore.shared.asksAboutOldSetting {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text("Настройка «разрешить очереди любые команды» заменена опасным режимом — отдельно для каждого проекта и на время. Сейчас очередь работает с обычными правами. Включить опасный режим для какого-нибудь проекта?")
                    .font(.callout)
                Spacer()
                Button("Не включать") { DangerModeStore.shared.answerOldSetting() }.buttonStyle(.glass)
                Menu("Выбрать проект…") {
                    ForEach(store.projects) { p in Button(p.displayName) { enabling = p } }
                }
                .fixedSize()
            }
            .padding(10)
            .background(.red.opacity(0.12))
            // Answered only once the mode is really on; a cancelled window leaves the question.
            .sheet(item: $enabling) { p in
                DangerModeSheet(project: p) { DangerModeStore.shared.answerOldSetting() }
            }
        }
    }
}
