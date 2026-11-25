import SwiftUI
import TrackTasksCore

struct UpdateSettingsSection: View {
    @AppStorage(Updater.enabledKey) private var enabled = true
    @State private var tt = TTLink.State.missing
    @State private var ttNote = ""

    private var updater: Updater { .shared }
    private var availability: UpdatePolicy.Availability { updater.availability }
    private var helper: URL { TTLink.helper(in: Bundle.main.bundleURL) }
    private var hasHelper: Bool { FileManager.default.isExecutableFile(atPath: helper.path) }

    var body: some View {
        Section("Обновления") {
            LabeledContent("Версия", value: updater.version)
            if availability.mayCheckByHand {
                Toggle("Проверять раз в сутки", isOn: $enabled)
                    .onChange(of: enabled) { updater.apply(); load() }
                Button("Проверить сейчас") { updater.check() }
                caption("Обновление скачивается и ставится только после подтверждения. Запрос не содержит данных о тебе и проектах; сервер видит IP-адрес.")
            } else {
                caption(availability.explanation)
            }
            if !updater.failure.isEmpty { caption("Обновления не запустились: " + updater.failure) }
            if let gate = updater.gate, gate.isPending {
                let busy = gate.busy
                HStack {
                    Label(busy.isEmpty ? "Обновление ждёт перезапуска" : "Перезапуск отложен: " + UpdatePolicy.text(busy),
                          systemImage: "clock.arrow.circlepath").foregroundStyle(.orange)
                    Spacer()
                    Button("Перезапустить") { gate.restart() }.disabled(!busy.isEmpty || gate.asking)
                }
            }
            if hasHelper { command }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private var command: some View {
        switch tt {
        case .linked: caption("tt обновляется вместе с приложением.")
        case .copy: link("~/.local/bin/tt — отдельная копия, она не обновляется.", "Заменить ссылкой")
        case .missing: link("Команды tt в ~/.local/bin нет.", "Создать ссылку")
        case .foreign: EmptyView()
        }
        if !ttNote.isEmpty { caption(ttNote) }
    }

    private func link(_ text: String, _ button: String) -> some View {
        HStack {
            caption(text)
            Spacer()
            Button(button) {
                do { try TTLink.link(TTLink.defaultPath, helper: helper); ttNote = "" }
                catch { ttNote = "Не получилось: " + error.localizedDescription }
                load()
            }
            .disabled(availability == .translocated || UpdatePolicy.isTranslocated(helper))
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }

    private func load() {
        updater.refresh()
        tt = TTLink.inspect(TTLink.defaultPath, helper: helper)
        // Homebrew links its own `tt`; an app of Homebrew doesn't offer another one.
        if availability == .homebrew, tt == .missing { tt = .foreign }
    }
}
