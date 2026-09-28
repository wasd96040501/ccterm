import Foundation

/// One run of a workflow a session started, and the agents it ran.
public struct WorkflowRun: Sendable, Hashable, Identifiable {
    /// The run id (`wf_…`).
    public let id: String
    /// The workflow's declared name, when its definition was recorded.
    public let name: String?
    /// Oldest first.
    public let agents: [SubagentFile]

    init(id: String, name: String?, agents: [SubagentFile]) {
        self.id = id
        self.name = name
        self.agents = agents
    }

    static func name(in definition: URL) -> String? {
        guard let data = try? Data(contentsOf: definition) else { return nil }
        return (try? JSONDecoder().decode(Definition.self, from: data))?.name
    }

    private struct Definition: Decodable {
        let name: String?

        init(from decoder: Decoder) throws {
            name = try decoder.container(keyedBy: AnyCodingKey.self).lenient(String.self, "workflowName")
        }
    }
}
