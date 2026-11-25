import Foundation

/// Decisions about updating the app itself: pure, the network and Sparkle are elsewhere.
public enum UpdatePolicy {
    /// What `Info.plist` of a published app says. Local builds have neither key.
    public struct Source: Equatable, Sendable {
        public let feed: URL
        /// Ed25519 public key, base64.
        public let key: String

        public init?(feed: String?, key: String?) {
            guard let feed, let url = URL(string: feed), url.scheme?.lowercased() == "https", url.host()?.isEmpty == false,
                  let key, Data(base64Encoded: key)?.count == 32 else { return nil }
            self.feed = url
            self.key = key
        }
    }

    public enum Availability: Equatable, Sendable {
        /// No feed or key: `build.sh`, `share.sh`, a release without keys.
        case noSource
        case homebrew
        /// Runs from a temporary read-only copy.
        case translocated
        /// Turned off in Settings: only «Проверить обновления…» goes to the network.
        case manualOnly
        case ready

        public var mayCheckByHand: Bool { self == .ready || self == .manualOnly }
        /// Shown in Settings; empty = nothing to explain.
        public var explanation: String {
            switch self {
            case .noSource: "Локальная сборка: обновлений у неё нет, они бывают только у опубликованной."
            case .homebrew: "Установлено через Homebrew. Обновление: brew upgrade --cask tracktasks"
            case .translocated: "Приложение запущено из временной папки macOS. Перенеси его в «Программы» и открой заново — тогда оно сможет обновляться."
            case .manualOnly, .ready: ""
            }
        }
    }

    public static func availability(source: Source?, app: URL, enabled: Bool,
                                    brewPrefixes: [URL] = Self.brewPrefixes) -> Availability {
        guard source != nil else { return .noSource }
        if ownedByHomebrew(app, prefixes: brewPrefixes) { return .homebrew }
        if isTranslocated(app) { return .translocated }
        return enabled ? .ready : .manualOnly
    }

    // MARK: Who owns this copy

    public static let brewPrefixes = ["/opt/homebrew", "/usr/local"].map { URL(fileURLWithPath: $0) }

    /// The cask leaves `Caskroom/tracktasks/<version>/TrackTasks.app`, a link to the installed app. The folder alone
    /// proves nothing: a copy put there by hand may live next to the cask's one.
    public static func ownedByHomebrew(_ app: URL, prefixes: [URL] = Self.brewPrefixes) -> Bool {
        let real = app.resolvingSymlinksInPath().standardizedFileURL.path
        return prefixes.contains { prefix in
            let cask = prefix.appendingPathComponent("Caskroom/tracktasks")
            let versions = (try? FileManager.default.contentsOfDirectory(at: cask, includingPropertiesForKeys: nil)) ?? []
            return versions.contains {
                let a = $0.appendingPathComponent("TrackTasks.app")
                return FileManager.default.fileExists(atPath: a.path) && a.resolvingSymlinksInPath().standardizedFileURL.path == real
            }
        }
    }

    public static func isTranslocated(_ app: URL) -> Bool { app.path.contains("/AppTranslocation/") }

    // MARK: Versions

    /// `1.10` → [1, 10]; nil = not a version of the app.
    public static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    /// Only a strictly newer version; what can't be read is refused.
    public static func isNewer(_ offered: String, than current: String) -> Bool {
        guard let a = numbers(offered), let b = numbers(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Restart

    /// What must not be cut off by a restart.
    public enum Busy: Hashable, Sendable {
        case task(String), merge(String), git, terminal(Int), server(Int), chat

        public var text: String {
            switch self {
            case .task(let t): "выполняется «\(t)»"
            case .merge(let t): t.isEmpty ? "идёт слияние или операция с веткой" : "идёт слияние или операция с веткой «\(t)»"
            case .git: "идёт операция git"
            case .terminal(let n): "открыты процессы терминала: \(n)"
            case .server(let n): "запущены dev-серверы: \(n)"
            case .chat: "Claude отвечает в чате"
            }
        }
    }

    public static func text(_ busy: [Busy]) -> String { busy.map(\.text).joined(separator: "; ") }
}
