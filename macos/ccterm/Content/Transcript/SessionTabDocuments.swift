import AgentSDK
import Foundation

/// The documents a session tab opens beside itself from its own controls —
/// the failure's *Show Log* and the context ring — as pre-resolved
/// `Document`s: nothing in the transcript backs them, so the tab never reloads
/// them and they have no way back to a row. Pure.
nonisolated enum SessionTabDocuments {
    /// What the CLI wrote to stderr before it quit, under the failure's message.
    static func log(_ failure: SessionFailure, transcriptURL: URL) -> Document {
        Document(
            reference: DocumentReference(transcriptURL: transcriptURL, id: "log"),
            content: .log(failure), workingDirectory: nil)
    }

    /// What `/context` shows, as the CLI last reported it. A different reading
    /// is a tab of its own.
    static func context(_ usage: ContextUsage, transcriptURL: URL) -> Document {
        Document(
            reference: DocumentReference(transcriptURL: transcriptURL, id: "context-\(usage.totalTokens)"),
            content: .contextUsage(usage), workingDirectory: nil)
    }
}
