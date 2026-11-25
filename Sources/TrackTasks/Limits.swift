import Foundation
import SwiftUI
import TrackTasksCore

/// Subscription usage windows (weekly, 5-hour…) taken from `rate_limit_event` in claude's stream-json.
/// Every Claude run refreshes them for free; `probe()` makes one tiny haiku call when data is stale.
@Observable @MainActor
final class Limits {
    static let shared = Limits()

    struct Window: Codable, Equatable {
        var utilization: Double   // 0…1 used
        var resetsAt: Date
        var status: String
        /// nil = not reported.
        var knownReset: Date? { resetsAt == .distantFuture ? nil : resetsAt }
    }

    private(set) var windows: [String: Window] = [:]
    private(set) var updated: Date?
    private(set) var isProbing = false
    @ObservationIgnored private var probeProc: ClaudeProcess?
    /// Called after every update (JobQueue re-checks the weekly-limit guard).
    @ObservationIgnored var onUpdate: (() -> Void)?

    private static let key = "limitsCache"
    private static let staleAfter: TimeInterval = 30 * 60

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let c = try? JSONDecoder().decode(Cache.self, from: d) {
            windows = c.windows
            updated = c.updated
        }
    }

    private struct Cache: Codable { var windows: [String: Window]; var updated: Date }

    /// What the queue's guard looks at.
    struct Snapshot { var weekly: Window?; var fiveHour: Window? }
    var snapshot: Snapshot { Snapshot(weekly: weekly, fiveHour: fiveHour) }

    /// Windows past their reset time are unknown, not "still used up".
    var weekly: Window? { windows["seven_day"].flatMap { $0.resetsAt > Date() ? $0 : nil } }
    var fiveHour: Window? { windows["five_hour"].flatMap { $0.resetsAt > Date() ? $0 : nil } }
    var isStale: Bool { updated.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true }

    func update(_ info: [String: Any]) {
        var w = windows
        if let unified = info["unifiedWindows"] as? [String: Any] {
            for (name, raw) in unified {
                guard let d = raw as? [String: Any], let u = d["utilization"] as? Double else { continue }
                let reset = (d["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantFuture
                w[name] = Window(utilization: u, resetsAt: reset,
                                 status: info["isUsingOverage"] as? Bool == true ? "overage" : d["status"] as? String ?? "")
            }
        } else if let type = info["rateLimitType"] as? String,
                  // A refusal comes without the number.
                  let u = info["utilization"] as? Double ?? (RunLimit(claude: info) != nil ? 1 : nil) {
            let reset = (info["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantFuture
            w[type] = Window(utilization: u, resetsAt: reset,
                             status: info["isUsingOverage"] as? Bool == true ? "overage" : info["status"] as? String ?? "")
        } else {
            return
        }
        // The refused window may be named apart from the list of windows.
        if info["unifiedWindows"] != nil, let r = RunLimit(claude: info), !r.window.isEmpty {
            w[r.window] = Window(utilization: 1, resetsAt: r.resetsAt ?? w[r.window]?.resetsAt ?? .distantFuture, status: "rejected")
        }
        // Drop windows that already reset — their numbers are no longer true.
        windows = w.filter { $0.value.resetsAt > Date() }
        updated = Date()
        if let d = try? JSONEncoder().encode(Cache(windows: windows, updated: updated!)) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
        onUpdate?()
    }

    /// Minimal haiku request just to receive the rate-limit event.
    func probe() {
        guard !isProbing, let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let p = ClaudeProcess()
        p.onExit = { [weak self] s in
            Spend.shared.add(s, project: "—", kind: "Проверка лимита")
            self?.isProbing = false
            self?.probeProc = nil
        }
        do {
            try p.start(ClaudeOptions.oneShot(cwd: root, prompt: "Ответь одним словом: ok", model: .haiku))
            probeProc = p
            isProbing = true
        } catch {
            isProbing = false
        }
    }

    func probeIfStale() {
        if isStale { probe() }
    }

    static func resetText(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func color(left: Double) -> Color {
        left > 0.4 ? .green : left > 0.15 ? .orange : .red
    }
}

/// Toolbar capsule: ring + "Неделя 65%" (left). Click refreshes.
struct WeeklyLimitBadge: View {
    private var limits: Limits { .shared }

    var body: some View {
        Button {
            limits.probe()
        } label: {
            HStack(spacing: 6) {
                if let w = limits.weekly {
                    let left = max(0, 1 - w.utilization)
                    ZStack {
                        Circle().stroke(.secondary.opacity(0.25), lineWidth: 2.5)
                        Circle().trim(from: 0, to: left)
                            .stroke(Limits.color(left: left), style: .init(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13)
                    Text("Неделя: \(Int((left * 100).rounded()))%")
                        .monospacedDigit()
                    if let h = limits.fiveHour {
                        Text("· 5ч: \(Int((max(0, 1 - h.utilization) * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                    Text("Лимит: —")
                }
                if limits.isProbing {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption.weight(.medium))
            .fixedSize()
        }
        .help(helpText)
        .onAppear { LaunchGate.shared.whenOpen { limits.probeIfStale() } }
    }

    private var helpText: String {
        guard let w = limits.weekly else {
            return "Нет данных о лимитах. Нажми, чтобы запросить (короткий запрос к Haiku)."
        }
        var s = "Недельный лимит: использовано \(Int((w.utilization * 100).rounded()))%, сброс \(Limits.resetText(w.resetsAt))"
        if let h = limits.fiveHour {
            s += "\n5-часовой: использовано \(Int((h.utilization * 100).rounded()))%, сброс \(Limits.resetText(h.resetsAt))"
        }
        if let u = limits.updated { s += "\nОбновлено \(Limits.resetText(u)). Нажми, чтобы обновить." }
        return s
    }
}
