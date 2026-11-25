import SwiftUI
import TrackTasksCore

/// Commit the ticked files with a message drafted by Claude (Haiku), optionally push.
struct CommitSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var files: [GitFile] = []
    @State private var selected: Set<Data> = []
    @State private var loaded = false
    @State private var pushPlan: GitBranches.PushPlan?
    @State private var pushNote = ""
    @State private var confirmLoss: PushChoice?
    @State private var message = ""
    @State private var drafting = false
    @State private var working = false
    @State private var result = ""
    @State private var failed = false
    @State private var proc: ClaudeProcess?
    @State private var risky: Set<String> = []

    private enum PushChoice { case commit, push }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "checkmark.diamond.fill").foregroundStyle(.green)
                Text("Коммит · \(project.displayName)").font(.title3.bold())
                Spacer()
                if let g = store.git[project.id] {
                    Pill(text: g.branch, color: .indigo, icon: "arrow.triangle.branch")
                }
            }
            HStack {
                Text("Изменения").font(.headline)
                Text("\(chosen.count) из \(files.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Все") { selected = Set(files.filter { $0.kind != .conflict }.map(\.id)) }
                Button("Ничего") { selected = [] }
            }
            .controlSize(.small)
            .disabled(working)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if files.isEmpty { Text(loaded ? "Нет изменений" : "Загрузка…").foregroundStyle(.secondary) }
                    ForEach(files) { fileRow($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 190)
            .padding(8)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            .disabled(working)
            if let why = blocked {
                Label(why, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            if !risky.isEmpty {
                Label("Похоже на секреты/личные данные — проверь отметки: \(risky.sorted().joined(separator: ", "))",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("Сообщение").font(.headline)
                if drafting { ProgressView().controlSize(.small); Text("Claude пишет…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { draft() } label: { Label("Ещё вариант", systemImage: "sparkles") }
                    .buttonStyle(.glass).controlSize(.small).disabled(drafting || chosen.isEmpty)
            }
            TextEditor(text: $message)
                .font(.body.monospaced())
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            if !result.isEmpty {
                Text(result)
                    .font(.caption.monospaced())
                    .foregroundStyle(failed ? .red : .green)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            if !pushNote.isEmpty { Text(pushNote).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Отмена") { proc?.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Коммит") { submit(.commit) }
                    .disabled(!canCommit)
                Button("Коммит и пуш") { submit(.push) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task { await load(); if !chosen.isEmpty { draft() } }
        .alert("Версия из индекса пропадёт", isPresented: Binding(get: { confirmLoss != nil }, set: { if !$0 { confirmLoss = nil } }),
               presenting: confirmLoss) { c in
            Button("Отмена", role: .cancel) {}
            Button("Снять с индекса", role: .destructive) { commit(push: c == .push, mayLose: true) }
        } message: { _ in
            Text("У этих файлов в индексе и в папке разное содержимое. В папке ничего не изменится, а подготовленная версия пропадёт:\n"
                 + GitStaging.lost(files, selected: selected).map(\.path).joined(separator: "\n"))
        }
        .onDisappear { proc?.stop() }
    }

    private var chosen: [GitFile] { files.filter { selected.contains($0.id) } }
    private var blocked: String? {
        if working { return nil }
        if files.contains(where: { $0.kind == .conflict }) { return "Есть неразрешённые конфликты — коммит невозможен" }
        return store.jobs.gitBlocked(project.url)
    }
    private var canCommit: Bool {
        !working && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chosen.isEmpty && blocked == nil
    }

    private func fileRow(_ f: GitFile) -> some View {
        Toggle(isOn: Binding(get: { selected.contains(f.id) }, set: { if $0 { selected.insert(f.id) } else { selected.remove(f.id) } })) {
            HStack(spacing: 6) {
                Text(String([f.index, f.worktree]).replacingOccurrences(of: ".", with: "·"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(f.oldPath.map { "\($0) → \(f.path)" } ?? f.path)
                    .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                let t = label(f)
                Text(t.0).font(.caption2).foregroundStyle(t.1).help(t.2)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(f.kind == .conflict)
        .help(f.path)
    }

    private func label(_ f: GitFile) -> (String, Color, String) {
        if f.isNestedRepo { return ("вложенный репозиторий", .orange, "Попадёт в коммит ссылкой, без файлов") }
        return switch f.kind {
        case .staged: ("в индексе", .green, "Подготовлен к коммиту")
        case .partial: ("частично в индексе", .orange, "В коммит пойдёт версия из индекса, правки в папке останутся")
        case .unstaged: ("изменён", .secondary, "")
        case .untracked: risky.contains(f.path) ? ("новый, проверь", .orange, "Похоже на секреты или личные данные") : ("новый", .blue, "")
        case .conflict: ("конфликт", .red, "")
        }
    }

    private func load() async {
        let url = project.url
        let (st, r, plan) = await GitOps.background {
            (GitStaging.status(url, git: GitOps.git), Set(GitInit.riskyFiles(url)), GitBranches.pushPlan(url, git: GitOps.git))
        }
        loaded = true
        switch st {
        case .failure(let e):
            files = []
            result = e.message
            failed = true
        case .success(let f):
            files = f
            // Untracked files only — tracked ones are already in history anyway.
            risky = r.intersection(f.filter { $0.kind == .untracked }.map(\.path))
        }
        selected = GitStaging.defaultSelection(files, risky: risky)
        showPlan(plan)
    }

    private func showPlan(_ plan: GitOps.Outcome<GitBranches.PushPlan>) {
        switch plan {
        case .success(let p):
            pushPlan = p
            pushNote = "Пуш: \(p.title)" + (p.setUpstream ? " (upstream будет создан)" : "")
        case .failure(let e):
            pushPlan = nil
            pushNote = "Пуш недоступен: \(e.message)"
        }
    }

    private func draft() {
        guard !drafting else { return }
        drafting = true
        let url = project.url, picked = chosen
        Task {
            let ctx = await GitOps.background {
                let log = Worktrees.git(["log", "-12", "--format=%s"], in: url).out
                var diff = GitStaging.diff(url, files: picked, git: GitOps.git)
                if diff.count > 24_000 { diff = String(diff.prefix(24_000)) + "\n…(обрезано)" }
                return (log, diff, picked.filter { $0.kind == .untracked }.prefix(300).map(\.path).joined(separator: "\n"))
            }
            let prompt = """
            Напиши сообщение git-коммита для изменений ниже. Следуй стилю истории проекта (язык, формат, префиксы вроде feat:/fix:, если они есть).
            Первая строка — до 72 символов. Если изменений много — пустая строка и 2–5 пунктов «- …».
            Ответь только текстом сообщения, без кавычек и пояснений.

            Последние коммиты:
            \(ctx.0)
            Новые файлы:
            \(ctx.2)
            Diff:
            \(ctx.1)
            """
            let p = ClaudeProcess()
            p.onExit = { s in
                drafting = false
                proc = nil
                Spend.shared.add(s, project: project.displayName, kind: "Сообщение коммита")
                let text = s.resultText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.failed, !text.isEmpty { message = text }
                else if message.isEmpty { result = "Claude не ответил — напиши сообщение сам"; failed = true }
            }
            do {
                try p.start(ClaudeOptions.oneShot(cwd: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                                                  prompt: prompt, model: .haiku))
                proc = p
            } catch {
                drafting = false
                result = error.localizedDescription
                failed = true
            }
        }
    }

    private func submit(_ c: PushChoice) {
        if GitStaging.lost(files, selected: selected).isEmpty { commit(push: c == .push, mayLose: false) } else { confirmLoss = c }
    }

    private func commit(push: Bool, mayLose: Bool) {
        working = true
        result = push ? "Коммит и пуш…" : "Коммит…"
        failed = false
        let url = project.url, msg = message, shown = files, ids = selected, plan = pushPlan, why = pushNote
        Task {
            var ok = true
            switch await GitOps.commit(url, message: msg, shown: shown, selected: ids, mayLose: mayLose, jobs: store.jobs) {
            case .failure(let e):
                ok = false
                await load()
                // The user's ticks stay; what appeared in the index meanwhile is ticked, so a retry doesn't drop it unseen.
                let seen = Set(shown.map(\.id))
                selected = Set(files.filter { $0.kind != .conflict && (ids.contains($0.id) || ($0.inIndex && !seen.contains($0.id))) }.map(\.id))
                result = e.message
            case .success(let t):
                result = t
                if push { ok = await send(plan, why: why) }
                // Committed: what is left is a new list.
                if !ok { await reloadCommitted() }
            }
            working = false
            failed = !ok
            store.refreshGit(project.id)
            if ok {
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            }
        }
    }

    private func reloadCommitted() async {
        let text = result
        await load()
        selected = []
        result = text
    }

    private func send(_ plan: GitBranches.PushPlan?, why: String) async -> Bool {
        var plan = plan
        // Before the first commit there was nothing to plan.
        if plan == nil, case .success(let p) = await GitOps.pushPlan(project.url) { plan = p }
        guard let plan else {
            result += "\n" + why
            return false
        }
        switch await GitOps.push(plan, in: project.url, exact: false) {
        case .success(let t): result += "\n" + t; return true
        case .failure(let e): result += "\nПуш не удался: " + e.message; return false
        }
    }
}
