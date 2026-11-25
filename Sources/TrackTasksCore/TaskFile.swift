import CryptoKit
import Foundation

/// A task file as it was read: the exact bytes are kept, so a write can detect that the file changed since.
public struct TaskFile: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case unreadable(String)
        case changed(String)
        /// The name is taken in the folder a task is moved to.
        case exists(String)
        case io(String)
    }

    public let url: URL
    public let data: Data
    public let text: String
    public var item: TaskItem

    /// Short content hash; changes with any byte of the file.
    public var rev: String { Self.rev(data) }

    static func rev(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public init(reading url: URL) throws {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw Failure.unreadable(url.path)
        }
        self.url = url
        self.data = data
        self.text = text
        item = Codec.task(from: text, url: url)
    }

    /// All task files of a folder in `Codec.tasks` order, with cross-file lint, and names that could not be read.
    /// `accept` is asked before a file is read; a refused one counts as unreadable.
    public static func all(in dir: URL, accept: (URL) -> Bool = { _ in true }) throws -> (files: [TaskFile], unreadable: [String]) {
        guard FileManager.default.fileExists(atPath: dir.path) else { return ([], []) }
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) }
        catch { throw Failure.io(error.localizedDescription) }
        var files: [TaskFile] = [], bad: [String] = []
        for u in urls where u.pathExtension.lowercased() == "md" {
            if accept(u), let f = try? TaskFile(reading: u) { files.append(f) } else { bad.append(u.lastPathComponent) }
        }
        files.sort { ($0.item.priorityRank, $0.item.created, $0.item.fileName) < ($1.item.priorityRank, $1.item.created, $1.item.fileName) }
        var items = files.map(\.item)
        TaskLint.crossCheck(&items, others: Codec.rawTasks(in: TaskFolder.archive.url(in: dir))
            + Codec.rawTasks(in: TaskFolder.drafts.url(in: dir)))
        for i in files.indices { files[i].item = items[i] }
        return (files, bad.sorted())
    }

    /// Replaces the file with `new`, unless its bytes differ from what was read.
    /// Returns false when there is nothing to change.
    @discardableResult
    public func write(_ new: String) throws -> Bool {
        try Self.locked(url.resolvingSymlinksInPath().deletingLastPathComponent()) { try replace(new) }
    }

    /// Reads the file and replaces it with what `change` makes of it, all under the folder lock.
    /// A writer that takes no lock (an agent) is noticed by the bytes: `change` then gets the newer text.
    @discardableResult
    public static func edit(_ url: URL, _ change: (TaskFile) throws -> String) throws -> TaskItem {
        try locked(url.resolvingSymlinksInPath().deletingLastPathComponent()) {
            for _ in 0..<5 {
                let file = try TaskFile(reading: url)
                let new = try change(file)
                do { try file.replace(new) } catch Failure.changed { continue }
                return Codec.task(from: new, url: url)
            }
            throw Failure.changed(url.lastPathComponent)
        }
    }

    /// Moves the file to the Trash; a file already gone is not an error.
    public static func trash(_ url: URL) throws {
        let dir = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try locked(dir) {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch CocoaError.fileNoSuchFile {}
            catch { throw Failure.io(error.localizedDescription) }
        }
    }

    /// `write` without the lock.
    @discardableResult
    private func replace(_ new: String) throws -> Bool {
        var new = new
        // `Codec` works with \n; a CRLF file keeps its line endings.
        if text.contains("\r\n") {
            new = new.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        }
        let out = Data(new.utf8)
        let target = url.resolvingSymlinksInPath()
        let mode = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        let tmp = try Self.temp(out, beside: target)
        defer { unlink(tmp.path) }
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path) }
        guard let now = try? Data(contentsOf: target), now == data else { throw Failure.changed(url.lastPathComponent) }
        if out == data { return false }
        guard rename(tmp.path, target.path) == 0 else { throw Failure.io(String(cString: strerror(errno))) }
        return true
    }

    /// Creates `YYYYMMDD-HHMMSS-slug.md`; never overwrites: a taken name moves the stamp a second forward.
    /// `check` runs under the folder lock: what it counted cannot change before the file appears.
    public static func create(_ item: TaskItem, in dir: URL, now: Date = Date(), check: () throws -> Void = {}) throws -> TaskFile {
        try create(text: Codec.serialize(item), slugOf: item.title, in: dir, now: now, check: check)
    }

    /// Same, with the file text given as is (imports write their own frontmatter).
    public static func create(text: String, slugOf title: String, in dir: URL, now: Date = Date(),
                              check: () throws -> Void = {}) throws -> TaskFile {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw Failure.io(error.localizedDescription) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let slug = Codec.slug(title)
        return try locked(dir) {
            try check()
            let tmp = try temp(Data(text.utf8), beside: dir.appendingPathComponent("new.md"))
            defer { unlink(tmp.path) }
            for shift in 0..<3600 {
                let name = f.string(from: now.addingTimeInterval(Double(shift))) + (slug.isEmpty ? "" : "-" + slug) + ".md"
                let url = dir.appendingPathComponent(name)
                if renamex_np(tmp.path, url.path, UInt32(RENAME_EXCL)) == 0 { return try TaskFile(reading: url) }
                guard errno == EEXIST else { throw Failure.io(String(cString: strerror(errno))) }
            }
            throw Failure.io("нет свободного имени файла")
        }
    }

    private static func temp(_ data: Data, beside url: URL) throws -> URL {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tt-\(UUID().uuidString).tmp")
        do { try data.write(to: tmp) } catch { unlink(tmp.path); throw Failure.io(error.localizedDescription) }
        return tmp
    }

    /// Serializes the app and `tt` processes writing to one folder (flock on the folder itself, no lock files).
    /// Blocks: never call it on the main thread. A holder that hangs ends in an error, not in endless waiting.
    static func locked<T>(_ dir: URL, timeout: TimeInterval = 30, _ body: () throws -> T) throws -> T {
        let fd = open(dir.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        defer { close(fd) }
        let start = ProcessInfo.processInfo.systemUptime
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EINTR || errno == EWOULDBLOCK else { throw Failure.io(String(cString: strerror(errno))) }
            guard ProcessInfo.processInfo.systemUptime - start < timeout else {
                throw Failure.io("папка \(dir.lastPathComponent) занята другой программой")
            }
            usleep(2000)
        }
        return try body()
    }
}
