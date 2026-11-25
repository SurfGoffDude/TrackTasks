import Foundation

/// `tt queue`: commands to the running app. queue.json is never touched from here.
extension CLI {
    func queue(_ args: CLIArgs) throws -> Output {
        let name = args.positional[0]
        guard let op = QueueOp(rawValue: name) else {
            throw CLIError.usage("tt queue \(name): есть " + QueueOp.allCases.map(\.rawValue).joined(separator: " | "))
        }
        let rest = Array(args.positional.dropFirst())
        let count: ClosedRange<Int> = switch op {
        case .list, .open: 0...0
        case .cancel, .log: 1...1
        case .answer: 2...2
        case .add: 1...Int.max
        }
        guard count.contains(rest.count) else { throw CLIError.usage("tt queue \(name): неверное число аргументов, см. tt help") }
        let allowed: [QueueOp: Set<String>] = [.list: ["all", "project"], .add: ["with-deps", "project"], .log: ["tail"]]
        for o in args.flags.union(args.values.keys).subtracting(["json"]) where allowed[op]?.contains(o) != true {
            throw CLIError.usage("tt queue \(name) не принимает --\(o)")
        }

        switch op {
        case .list: return try queueList(args)
        case .add: return try queueAdd(rest, args)
        case .cancel:
            return jobs(name, try ask(QueueRequest(.cancel, job: rest[0])), "Отмена принята")
        case .answer:
            guard let text = rest[1] == "-" ? stdin() : rest[1] else {
                throw CLIError.usage("tt queue answer: нет данных в stdin (или не UTF-8)")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.usage("tt queue answer: пустое сообщение")
            }
            return jobs(name, try ask(QueueRequest(.answer, job: rest[0], text: text)), "Сообщение отправлено")
        case .log:
            var tail = 50
            if let v = try args.one("tail") {
                guard let n = Int(v), (1...QueueProtocol.maxLogLines).contains(n) else {
                    throw CLIError.usage("--tail \(v): число от 1 до \(QueueProtocol.maxLogLines)")
                }
                tail = n
            }
            var ref = rest[0]
            // Resolved here among the visible jobs: neither the log nor an «ambiguous» error shows the others.
            if confined { ref = try QueueJob.find(ref, in: visible(ask(QueueRequest(.list)).jobs ?? [])).id }
            let r = try ask(QueueRequest(.log, job: ref, tail: tail))
            if confined, visible(r.jobs ?? []).first?.id != ref { throw CLIError.notFound("в очереди нет «\(rest[0])»") }
            let log = r.log ?? []
            return Output(json: ["action": name, "job": r.jobs?.first.map(json) ?? NSNull(), "log": log],
                          text: log.isEmpty ? "Лог пуст\n" : clean(log.joined(separator: "\n")) + "\n")
        case .open:
            _ = try ask(QueueRequest(.open))
            return Output(json: ["action": name], text: "Очередь открыта\n")
        }
    }

    private func ask(_ r: QueueRequest) throws -> QueueResponse { try transport(r) }

    private func queueList(_ args: CLIArgs) throws -> Output {
        let only = args.values["project"] == nil ? nil : try projectURL(args).resolvingSymlinksInPath().path
        let r = try ask(QueueRequest(.list))
        let picked = visible(r.jobs ?? []).filter { j in
            (args.has("all") || j.isActive || j.awaitsMerge)
                && (only == nil || URL(fileURLWithPath: j.projectPath).resolvingSymlinksInPath().path == only)
        }
        let paused = r.paused == true
        let text = (paused ? "Очередь на паузе\n" : "")
            + (picked.isEmpty ? "Очередь пуста\n" : picked.map(line).joined())
        return Output(json: ["action": "list", "paused": paused, "jobs": picked.map(json)], text: text)
    }

    private func queueAdd(_ refs: [String], _ args: CLIArgs) throws -> Output {
        var project: URL?
        var names: [String] = []
        for ref in refs {
            let (ctx, f) = try task(ref, args)
            if let project, project.path != ctx.url.path { throw CLIError.usage("tt queue add: задачи из разных проектов") }
            project = ctx.url
            if !names.contains(f.item.fileName) { names.append(f.item.fileName) }
        }
        let r = try ask(QueueRequest(.add, project: project?.path, tasks: names, withDeps: args.has("with-deps")))
        return jobs("add", r, "В очереди")
    }

    private func jobs(_ action: String, _ r: QueueResponse, _ verb: String) -> Output {
        let list = r.jobs ?? []
        return Output(json: ["action": action, "jobs": list.map(json)], text: list.map { "\(verb): \(line($0))" }.joined())
    }

    private func line(_ j: QueueJob) -> String {
        var tags = [j.state]
        if j.permissions > 0 { tags.append("ждёт разрешения: \(j.permissions)") }
        if j.awaitsMerge { tags.append("ждёт слияния") }
        // The reason covers a plan waiting for approval too.
        if !j.waitReason.isEmpty { tags.append(j.waitReason) }
        let s = "\(j.id.prefix(8).lowercased()) \(j.project): \(j.title) (\(tags.joined(separator: ", ")))"
        return clean(s.components(separatedBy: .newlines).joined(separator: " ")) + "\n"
    }

    private func json(_ j: QueueJob) -> [String: Any] {
        ["id": j.id, "kind": j.kind, "state": j.state, "title": j.title,
         "project": ["name": j.project, "path": j.projectPath], "file": j.taskFile ?? NSNull() as Any,
         "path": j.taskPath ?? NSNull() as Any, "lastLine": orNull(j.lastLine), "waitReason": orNull(j.waitReason),
         "permissions": j.permissions, "awaitingPlan": j.awaitingPlan, "awaitsMerge": j.awaitsMerge]
    }
}
