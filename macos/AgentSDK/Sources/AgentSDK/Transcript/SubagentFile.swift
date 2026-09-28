import Foundation

/// One subagent's transcript on disk. Read it with
/// ``Transcript/init(contentsOf:)``.
public struct SubagentFile: Sendable, Hashable {
    public let url: URL
    /// The task the agent was given (the Agent tool's `description`).
    public let task: String?
    /// `general-purpose`, `Explore`, a custom agent's name, …
    public let agentType: String?

    init(url: URL, task: String?, agentType: String?) {
        self.url = url
        self.task = task
        self.agentType = agentType
    }

    /// The `agent-*.jsonl` files in `directory`, oldest first, each with what
    /// its `.meta.json` sidecar records.
    static func files(in directory: URL) -> [SubagentFile] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: .skipsHiddenFiles)) ?? []
        return
            entries
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }
            .sorted { $0.creationDate < $1.creationDate }
            .map { url in
                let sidecar = url.deletingPathExtension().appendingPathExtension("meta.json")
                let meta = (try? Data(contentsOf: sidecar)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
                return SubagentFile(url: url, task: meta?.description, agentType: meta?.agentType)
            }
    }

    private struct Meta: Decodable {
        let description: String?
        let agentType: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            description = c.lenient(String.self, "description")
            agentType = c.lenient(String.self, "agentType")
        }
    }
}
