import Foundation

/// Saved settings domains. Throws when a domain exists but can't be read: that is not "no settings".
public protocol SettingsDomains {
    func read(_ domain: String) throws -> [String: Any]
    func write(_ values: [String: Any], to domain: String) throws
}

/// One-time copy of the settings from the previous app identifier. The previous domain is only read.
public enum SettingsMigration {
    public static let currentID = "io.github.surfgoffdude.TrackTasks"
    public static let legacyID = "local.artemshloyda.TrackTasks"
    public static let markerKey = "settingsMigrated"

    public enum Failure: LocalizedError, Equatable {
        case previousIsRunning
        case unreadable(String)
        case notSaved

        public var errorDescription: String? {
            switch self {
            case .previousIsRunning: "Запущена прежняя версия TrackTasks. Закройте её: обе работали бы с одной очередью."
            case .unreadable(let domain): "Не удалось прочитать настройки «\(domain)»."
            case .notSaved: "Не удалось сохранить перенесённые настройки."
            }
        }
    }

    /// `start` runs only when the settings are in place; otherwise the reason is returned.
    public static func launch(domains: SettingsDomains, previousIsRunning: Bool,
                              from legacy: String = legacyID, to current: String = currentID,
                              start: () -> Void) -> Error? {
        do {
            // Also after the move: both copies would share queue.json and the socket.
            if previousIsRunning { throw Failure.previousIsRunning }
            try migrate(domains: domains, from: legacy, to: current)
        } catch {
            return error
        }
        start()
        return nil
    }

    static func migrate(domains: SettingsDomains, from legacy: String, to current: String) throws {
        let before = try domains.read(current)
        if before[markerKey] as? Bool == true { return }
        // The whole domain: some keys are dynamic. What is already set in the new one stays.
        var merged = try domains.read(legacy).merging(before) { _, new in new }
        merged[markerKey] = nil
        do {
            // The marker goes last, after the copy has been checked.
            try save(merged, to: current, domains)
            merged[markerKey] = true
            try save(merged, to: current, domains)
        } catch {
            // A half-written copy must not pass for the user's new values on the next try.
            try? domains.write(before, to: current)
            throw error
        }
    }

    private static func save(_ values: [String: Any], to domain: String, _ domains: SettingsDomains) throws {
        try domains.write(values, to: domain)
        guard (try domains.read(domain) as NSDictionary).isEqual(to: values) else { throw Failure.notSaved }
    }

    /// For `tt`, which only reads: before the move a missing key is looked up in the previous domain.
    public static func value(_ key: String, domains: SettingsDomains,
                             from legacy: String = legacyID, to current: String = currentID) -> Any? {
        let now = (try? domains.read(current)) ?? [:]
        if let value = now[key] { return value }
        if now[markerKey] as? Bool == true { return nil }
        return (try? domains.read(legacy))?[key]
    }
}

/// The user's real settings.
public struct UserDefaultsDomains: SettingsDomains {
    private let preferences: URL

    public init(preferences: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")) {
        self.preferences = preferences
    }

    public func read(_ domain: String) throws -> [String: Any] {
        let values = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        guard values.isEmpty else { return values }
        // Empty is also what an unreadable domain looks like: ask the file.
        let file = preferences.appendingPathComponent(domain + ".plist")
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            throw SettingsMigration.Failure.unreadable(domain)
        }
        guard let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], saved.isEmpty
        else { throw SettingsMigration.Failure.unreadable(domain) }
        return [:]
    }

    public func write(_ values: [String: Any], to domain: String) throws {
        UserDefaults.standard.setPersistentDomain(values, forName: domain)
        guard CFPreferencesAppSynchronize(domain as CFString) else { throw SettingsMigration.Failure.notSaved }
    }
}
