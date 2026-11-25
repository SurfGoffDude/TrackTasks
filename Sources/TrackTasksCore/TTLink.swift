import Foundation

/// `tt` in the user's PATH: a link to the one inside the app is updated together with it, a copy goes stale.
public enum TTLink {
    public enum State: Equatable, Sendable {
        case missing
        /// Leads to the `tt` of this app.
        case linked
        /// A separate copy of our `tt` (`build.sh --install`).
        case copy
        /// Another program, a link of Homebrew or of another copy of the app: not ours to touch.
        case foreign
    }

    public static var defaultPath: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/tt") }
    /// Inside the published app only.
    public static func helper(in app: URL) -> URL { app.appendingPathComponent("Contents/Helpers/tt") }

    public static func inspect(_ path: URL, helper: URL) -> State {
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: path.path) else { return .missing }
        switch a[.type] as? FileAttributeType {
        case .typeSymbolicLink:
            return path.resolvingSymlinksInPath().standardizedFileURL.path == helper.resolvingSymlinksInPath().standardizedFileURL.path
                && fm.fileExists(atPath: helper.path) ? .linked : .foreign
        case .typeRegular:
            return isOurs(path) ? .copy : .foreign
        default:
            return .foreign
        }
    }

    public struct Refused: LocalizedError {
        public let errorDescription: String?
    }

    /// Puts the link in place of a copy of ours (or of nothing) by a rename: a running `tt` is not cut off.
    public static func link(_ path: URL, helper: URL) throws {
        guard !UpdatePolicy.isTranslocated(helper) else { throw Refused(errorDescription: "приложение запущено из временной папки macOS") }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw Refused(errorDescription: "в приложении нет tt") }
        switch inspect(path, helper: helper) {
        case .linked: return
        case .foreign: throw Refused(errorDescription: "\(path.path) — другая программа")
        case .missing, .copy: break
        }
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".tt.\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: temp.path, withDestinationPath: helper.path)
        guard rename(temp.path, path.path) == 0 else {
            let why = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temp)
            throw Refused(errorDescription: why)
        }
    }

    /// The same sign as in `build.sh`; a Mach-O, so that someone's script mentioning TrackTasks isn't taken for ours.
    private static func isOurs(_ path: URL) -> Bool {
        guard let d = try? Data(contentsOf: path, options: .mappedIfSafe), d.count > 4 else { return false }
        let magic = [UInt8](d.prefix(4))
        guard [[0xCF, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE]].contains(magic) else { return false }
        return d.range(of: Data("TrackTasks".utf8)) != nil
    }
}
