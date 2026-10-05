import DisplayModels
import Foundation

/// A document as a tab beside the transcript receives it: what it is, where
/// it came from, and the session directory its paths are read against.
nonisolated struct Document: Sendable, Equatable {
    let reference: DocumentReference
    let content: DocumentContent
    let workingDirectory: String?

    /// What the approval bar over it asks, while the call it is about waits
    /// for the reader.
    var approval: Approval? {
        guard let call, case .waiting = call.state else { return nil }
        return Approval(call)
    }

    /// Whether the call it is about is still going, so a live session can
    /// still change it; a settled document never changes.
    var isLive: Bool {
        call?.state.isLive ?? false
    }

    private var call: ToolCall? {
        switch content {
        case .command(let call), .newFile(let call), .read(let call), .search(let call), .web(let call),
            .agent(let call), .advice(let call), .sentMessage(let call), .other(let call):
            call
        case .change(let calls): calls.last
        case .shellCommand, .agentMessage, .taskList, .news, .commandOutput, .log, .contextUsage,
            .compactionSummary, .continuationPrompt, .image:
            nil
        }
    }
}
