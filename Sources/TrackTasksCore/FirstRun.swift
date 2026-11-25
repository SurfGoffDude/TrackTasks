import Foundation

/// Is it a new user: decided once, before anything of this launch is written.
public enum FirstRun {
    /// true = finished or skipped, false = shown but not finished, absent = never shown.
    public static let doneKey = "onboardingDone"

    /// `settings`: the app's own domain, nil = not known. `hasData`: anything in Application Support/TrackTasks.
    /// In doubt the user isn't new.
    public static func isNeeded(settings: [String: Any]?, hasData: Bool) -> Bool {
        guard let settings else { return false }
        if let done = settings[doneKey] as? Bool { return !done }
        return !hasData && !settings.keys.contains(where: isOwn)
    }

    /// macOS and Sparkle keep their keys in the same domain.
    static func isOwn(_ key: String) -> Bool {
        key != SettingsMigration.markerKey && !["NS", "SU", "Apple", "com.apple", "com_apple"].contains { key.hasPrefix($0) }
    }
}
