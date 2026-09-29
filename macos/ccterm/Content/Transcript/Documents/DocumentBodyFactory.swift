import AppKit

/// Which view controller shows a document under its jump bar — the one
/// place a kind of document meets its body.
///
/// A subagent's work opens as its conversation — the transcript it wrote,
/// in a `TranscriptViewController` like the session's own — when that file
/// is on disk; its report as markdown otherwise.
@MainActor
struct DocumentBodyFactory {
    /// Reads a subagent's conversation.
    let loadTranscript: TranscriptViewController.Load
    /// Where a subagent's conversation reports what the reader opens in it.
    weak var transcriptDelegate: TranscriptViewControllerDelegate?

    func body(for document: Document) -> NSViewController {
        switch document.content {
        case .command(let call):
            return CommandDocumentViewController(.call(call))
        case .shellCommand(let command):
            return CommandDocumentViewController(.local(command))
        case .change(let calls):
            return SourceDocumentViewController(.change(calls))
        case .newFile(let call):
            return SourceDocumentViewController(.newFile(call))
        case .read(let call):
            return SourceDocumentViewController(.read(call))
        case .agent(let call):
            if let agentID = call.agentID {
                let url = document.reference.conversationURL(ofAgent: agentID)
                if FileManager.default.fileExists(atPath: url.path) {
                    let conversation = TranscriptViewController(
                        fileURL: url, title: DocumentHeader(document).title, load: loadTranscript)
                    conversation.delegate = transcriptDelegate
                    return conversation
                }
            }
            return MarkdownDocumentViewController(markdown: DocumentMarkdown.markdown(for: document.content))
        case .search, .web, .taskList, .news, .commandOutput, .compactionSummary, .other:
            return MarkdownDocumentViewController(markdown: DocumentMarkdown.markdown(for: document.content))
        }
    }
}
