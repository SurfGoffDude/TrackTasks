import SwiftUI
import AppKit

/// ⌘⇧N: add a task anywhere. "Auto" lets Claude pick the project.
struct QuickAddSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var projectID: String = ""
    @State private var template: TaskTemplate = .blank
    @State private var saving = false
    @State private var error = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Быстрая задача", systemImage: "plus.circle.fill")
                .font(.title2.weight(.semibold))
            TextField("Что сделать? Например: «в ForHer поправить загрузку медиа»", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .focused($focused)
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            HStack {
                ProjectPicker(selection: $projectID)
                Picker("Шаблон", selection: $template) {
                    ForEach(TaskTemplate.allCases) { t in Label(t.title, systemImage: t.icon).tag(t) }
                }
                .frame(maxWidth: 220)
            }
            Text(projectID.isEmpty
                 ? "Claude сам определит проект по описанию (в фоне, видно в «Очереди»)."
                 : "Задача сразу создастся в выбранном проекте.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Добавить") {
                    saving = true
                    error = ""
                    store.quickAdd(text, to: store.project(projectID.isEmpty ? nil : projectID), template: template) { why in
                        saving = false
                        if let why { error = why } else { dismiss() }
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            projectID = store.selectedProject?.id ?? ""
            focused = true
        }
    }
}

struct ProjectPicker: View {
    @Environment(Store.self) private var store
    @Binding var selection: String

    var body: some View {
        Picker("Проект", selection: $selection) {
            Label("Авто — Claude выберет", systemImage: "sparkles").tag("")
            if !store.pinnedProjects.isEmpty {
                Section("Закреплённые") {
                    ForEach(store.pinnedProjects) { p in Text(p.displayName).tag(p.id) }
                }
            }
            ForEach(store.grouped(excludingPinned: true), id: \.category) { g in
                Section(g.category) {
                    ForEach(g.projects) { p in Text(p.displayName).tag(p.id) }
                }
            }
        }
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""
    @State private var projectID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TrackTasks").font(.headline)
                Spacer()
                if Spend.shared.today > 0 {
                    Text(String(format: "$%.2f сегодня", Spend.shared.today))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            WeeklyLimitBadge()
                .buttonStyle(.glass)
                .controlSize(.small)

            DangerBar()

            VStack(alignment: .leading, spacing: 6) {
                TextField("Новая задача…", text: $text)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    .onSubmit(add)
                HStack {
                    ProjectPicker(selection: $projectID)
                        .labelsHidden()
                        .controlSize(.small)
                    Button("Добавить", action: add)
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            let doing = store.doingTasks
            if !doing.isEmpty {
                Divider()
                Text("В работе").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(doing.prefix(8), id: \.task.id) { item in
                    Button {
                        show(item.project.id)
                    } label: {
                        HStack {
                            Image(systemName: store.jobs.job(forTask: item.task.id) != nil ? "sparkles" : "bolt.fill")
                                .foregroundStyle(store.jobs.job(forTask: item.task.id) != nil ? .orange : .blue)
                            Text(item.task.title).lineLimit(1)
                            Spacer()
                            Text(item.project.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            let running = store.jobs.jobs.filter(\.isActive)
            if !running.isEmpty {
                Divider()
                Button { show(Store.queueID) } label: {
                    HStack {
                        ProgressView().controlSize(.mini)
                        Text("Агент: \(running.count) в очереди")
                        Spacer()
                        if store.jobs.waitingApproval > 0 {
                            Label("\(store.jobs.waitingApproval)", systemImage: "hand.raised.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if let current = running.first(where: { $0.state == .running }) {
                    Text(current.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Divider()
            HStack {
                Button("Сводка дня") {
                    show(Store.dashboardID)
                    store.morningDigest()
                }
                Spacer()
                Button("Открыть") { show(nil) }
                Button("Выйти") { NSApp.terminate(nil) }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }

    private func add() {
        let sent = text
        store.quickAdd(text, to: store.project(projectID.isEmpty ? nil : projectID), template: .blank) { why in
            if let why { store.taskError = why } else if text == sent { text = "" }
        }
    }

    private func show(_ id: String?) {
        if let id { store.selectedID = id }
        openWindow(id: "main")
        NSApp.activate()
    }
}
