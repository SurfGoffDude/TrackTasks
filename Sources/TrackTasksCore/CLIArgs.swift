import Foundation

/// Parsed command line of `tt`. No external dependencies.
struct CLIArgs {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags = Set<String>()

    /// Already parsed values (MCP): nothing in them can turn into an option.
    init(positional: [String] = [], values: [String: [String]] = [:], flags: Set<String> = []) {
        self.positional = positional
        self.values = values
        self.flags = flags
    }

    /// `options` take a value (`--x v`, `--x=v`), `flags` do not. After `--` everything is positional.
    init(_ args: [String], options: Set<String>, flags known: Set<String>) throws {
        let short = ["-p": "project", "-a": "all", "-h": "help"]
        var i = 0
        while i < args.count {
            let a = args[i]
            i += 1
            if a == "--" { positional += args[i...]; break }
            var name: String
            var inline: String?
            if let s = short[a] {
                name = s
            } else if a.hasPrefix("--") {
                name = String(a.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: eq)...])
                    name = String(name[..<eq])
                }
            } else if a.hasPrefix("-"), a.count > 1 {
                throw CLIError.usage("неизвестный параметр \(a)")
            } else {
                positional.append(a)
                continue
            }
            if known.contains(name) {
                guard inline == nil else { throw CLIError.usage("--\(name) не принимает значение") }
                flags.insert(name)
            } else if options.contains(name) {
                if let inline { values[name, default: []].append(inline); continue }
                guard i < args.count, !args[i].hasPrefix("--") else {
                    throw CLIError.usage("--\(name): нужно значение (если оно начинается с «--», пиши --\(name)=…)")
                }
                values[name, default: []].append(args[i])
                i += 1
            } else {
                throw CLIError.usage("неизвестный параметр \(a)")
            }
        }
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func all(_ name: String) -> [String] { values[name] ?? [] }

    func one(_ name: String) throws -> String? {
        let v = all(name)
        guard v.count < 2 else { throw CLIError.usage("--\(name) указан несколько раз") }
        return v.first
    }

    /// Value that becomes one line of the file.
    func line(_ name: String) throws -> String? { try one(name).map { try CLIArgs.line($0, "--" + name) } }
    func lines(_ name: String) throws -> [String] { try all(name).map { try CLIArgs.line($0, "--" + name) } }

    static func line(_ s: String, _ what: String) throws -> String {
        let out = s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !out.isEmpty else { throw CLIError.usage("\(what): пустое значение") }
        return out
    }

    func choice<T: RawRepresentable & CaseIterable>(_ name: String, _ type: T.Type) throws -> T? where T.RawValue == String {
        try one(name).map { try CLIArgs.parse($0, name, type) }
    }

    func choices<T: RawRepresentable & CaseIterable>(_ name: String, _ type: T.Type) throws -> [T] where T.RawValue == String {
        try all(name).flatMap { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            .map { try CLIArgs.parse($0, name, type) }
    }

    private static func parse<T: RawRepresentable & CaseIterable>(_ v: String, _ name: String, _ type: T.Type) throws -> T
        where T.RawValue == String {
        guard let x = T(rawValue: v) else {
            throw CLIError.usage("--\(name) \(v): допустимо " + T.allCases.map(\.rawValue).joined(separator: " | "))
        }
        return x
    }
}

/// Exit codes are part of the `tt` contract (see `tt instructions`).
struct CLIError: Error, Equatable {
    enum Code: Int32 {
        case io = 1, usage = 2, notFound = 3, conflict = 4, invalid = 5, unavailable = 6

        var name: String {
            switch self {
            case .io: "io"
            case .usage: "usage"
            case .notFound: "not_found"
            case .conflict: "conflict"
            case .invalid: "invalid"
            case .unavailable: "unavailable"
            }
        }
    }

    var code: Code
    var message: String

    static func usage(_ m: String) -> CLIError { CLIError(code: .usage, message: m) }
    static func notFound(_ m: String) -> CLIError { CLIError(code: .notFound, message: m) }
    static func conflict(_ m: String) -> CLIError { CLIError(code: .conflict, message: m) }
    static func invalid(_ m: String) -> CLIError { CLIError(code: .invalid, message: m) }

    init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    init(_ error: Error) {
        switch error {
        case let e as CLIError: self = e
        case TaskFile.Failure.changed(let f): self = .conflict("\(f) изменился с момента чтения, запись отменена")
        case TaskFile.Failure.exists(let f): self = .conflict("\(f): имя уже занято")
        case TaskFile.Failure.unreadable(let f): self = CLIError(code: .io, message: "не читается (или не UTF-8): \(f)")
        case TaskFile.Failure.io(let m): self = CLIError(code: .io, message: m)
        case let e as QueueFailure:
            let code: Code = switch e.code {
            case .io: .io
            case .usage: .usage
            case .notFound: .notFound
            case .conflict: .conflict
            case .invalid: .invalid
            case .unavailable, .version: .unavailable
            }
            self = CLIError(code: code, message: e.code == .version ? e.message + " — обнови приложение и tt (./build.sh --install)" : e.message)
        default: self = CLIError(code: .io, message: error.localizedDescription)
        }
    }
}
