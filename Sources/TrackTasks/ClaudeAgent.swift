import Foundation
import TrackTasksCore

/// Claude Code CLI — the first agent of the queue.
struct ClaudeAgent: Agent {
    let id = AgentID.claude
    let title = "Claude"
    let capabilities: AgentCapabilities = [.resume, .fork, .resumeAt, .permissions, .isolation, .autoModel, .cost, .guardedLimit, .bypass, .container, .images]

    func makeRun() -> any AgentRun { ClaudeProcess() }
}

extension AgentRegistry {
    static let standard = AgentRegistry([ClaudeAgent(), CodexAgent(), SSHAgent(), ACPAgent()])
}

extension ClaudeOptions {
    init(_ r: AgentRequest) {
        let tools: [String] = switch r.access {
        case .planning: ClaudeTools.planning
        case .coding: ClaudeTools.coding
        case .answer: []
        }
        self.init(cwd: r.cwd, prompt: r.prompt, systemPrompt: r.systemPrompt, model: r.model,
                  resume: r.resume, fork: r.fork, resumeAt: r.resumeAt, bypassPermissions: r.bypassPermissions,
                  allowedTools: tools, addDirs: r.addDirs, isolated: r.isolated,
                  tools: r.access == .answer ? [] : nil, images: r.images)
    }
}

extension ClaudeProcess {
    func start(_ request: AgentRequest) throws { try start(ClaudeOptions(request)) }
}

/// Profiles from Settings.
enum AgentProfileStore {
    static let key = "agentProfiles"

    static var current: AgentProfiles {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(AgentProfiles.self, from: $0) } ?? AgentProfiles() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}
