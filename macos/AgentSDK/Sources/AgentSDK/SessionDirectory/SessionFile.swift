import Foundation

/// A session's main transcript on disk, as ``SessionDirectory/sessions()``
/// lists it, and the side transcripts the session spawned.
public struct SessionFile: Sendable, Hashable, Identifiable {
    /// The session id.
    public var id: String { url.deletingPathExtension().lastPathComponent }
    public let url: URL
    public let modificationDate: Date

    init(url: URL, modificationDate: Date) {
        self.url = url
        self.modificationDate = modificationDate
    }

    /// The subagents the session started with the Agent tool, oldest first.
    /// Agents a workflow ran are under ``workflows()`` instead.
    public func subagents() -> [SubagentFile] {
        SubagentFile.files(in: subagentsDirectory)
    }

    /// The workflow runs the session started, oldest first.
    public func workflows() -> [WorkflowRun] {
        let runs =
            (try? FileManager.default.contentsOfDirectory(
                at: subagentsDirectory.appendingPathComponent("workflows", isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: .skipsHiddenFiles)) ?? []
        let definitions = sessionDirectory.appendingPathComponent("workflows", isDirectory: true)
        return runs.filter(\.isDirectory)
            .sorted { $0.creationDate < $1.creationDate }
            .map { run in
                let id = run.lastPathComponent
                let definition = definitions.appendingPathComponent("\(id).json")
                return WorkflowRun(
                    id: id, name: WorkflowRun.name(in: definition), agents: SubagentFile.files(in: run))
            }
    }

    /// `<session id>/` beside the transcript: everything the session spawned.
    private var sessionDirectory: URL {
        url.deletingPathExtension()
    }

    private var subagentsDirectory: URL {
        sessionDirectory.appendingPathComponent("subagents", isDirectory: true)
    }
}
