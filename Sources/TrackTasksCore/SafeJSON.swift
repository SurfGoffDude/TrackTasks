import Foundation

/// Safe JSON persistence: a broken file is never silently replaced by an empty list.
public enum SafeJSON {
    public enum Loaded<T> {
        case missing
        case value(T)
        /// File was undecodable; it was moved to `backup` (nil if the move failed — then writes to `url` are blocked).
        case corrupt(backup: URL?, error: String)
        /// File could not be read (I/O, permissions). Left in place; writes to `url` are blocked.
        case unreadable(error: String)
    }

    public enum SaveError: LocalizedError {
        case blocked(String)
        public var errorDescription: String? {
            switch self {
            case .blocked(let name): return "запись в \(name) заблокирована: исходный файл не удалось ни прочитать, ни сохранить копией"
            }
        }
    }

    /// Paths where an unreadable/unmovable original is still on disk; saving would destroy it.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var blocked = Set<String>()

    private static func setBlocked(_ url: URL, _ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on { blocked.insert(url.standardizedFileURL.path) } else { blocked.remove(url.standardizedFileURL.path) }
    }

    public static func isBlocked(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return blocked.contains(url.standardizedFileURL.path)
    }

    public static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder(), now: Date = Date()) -> Loaded<T> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { setBlocked(url, false); return .missing }

        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            // Read failure is not proof of corruption: do not move the file, do not allow overwriting it.
            setBlocked(url, true)
            NSLog("SafeJSON: \(url.lastPathComponent) не удалось прочитать (\(error))")
            return .unreadable(error: error.localizedDescription)
        }

        do {
            let v = try decoder.decode(T.self, from: data)
            setBlocked(url, false)
            return .value(v)
        } catch {
            let backup = uniqueSibling(url, suffix: "corrupt-" + stamp(now))
            // Move (not copy): the original path is freed, so the next save cannot rotate garbage into .bak.
            var moved: URL? = backup
            do { try fm.moveItem(at: url, to: backup) } catch { moved = nil }
            setBlocked(url, moved == nil)
            NSLog("SafeJSON: \(url.lastPathComponent) повреждён (\(error)); копия: \(moved?.lastPathComponent ?? "не удалось сохранить")")
            return .corrupt(backup: moved, error: String(describing: error))
        }
    }

    /// Writes atomically; keeps the previous version as `name.bak.json` (only when content changes).
    /// Returns a warning if the `.bak` could not be refreshed; throws if the write itself failed or is blocked.
    @discardableResult
    public static func save(_ data: Data, to url: URL) throws -> String? {
        if isBlocked(url) { throw SaveError.blocked(url.lastPathComponent) }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var warning: String?
        if fm.fileExists(atPath: url.path) {
            if let old = try? Data(contentsOf: url), old == data {
                // Nothing changed: keep the older .bak as is.
            } else {
                let bak = sibling(url, suffix: "bak", now: Date())
                do {
                    if fm.fileExists(atPath: bak.path) { try fm.removeItem(at: bak) }
                    try fm.copyItem(at: url, to: bak)
                } catch {
                    warning = "Не удалось обновить резервную копию \(bak.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
        try data.write(to: url, options: .atomic)
        return warning
    }

    public static func sibling(_ url: URL, suffix: String, now: Date) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).\(suffix).\(url.pathExtension)")
    }

    /// Like `sibling`, but never collides with an existing file (adds -2, -3, …).
    static func uniqueSibling(_ url: URL, suffix: String) -> URL {
        var candidate = sibling(url, suffix: suffix, now: Date())
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = sibling(url, suffix: "\(suffix)-\(n)", now: Date())
            n += 1
        }
        return candidate
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }
}
