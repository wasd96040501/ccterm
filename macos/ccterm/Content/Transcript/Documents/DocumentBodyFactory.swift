import AppKit

/// Which view controller shows a document under its jump bar — the one
/// place a kind of document meets its body.
///
/// A subagent's work opens as its conversation — the transcript it wrote —
/// when that file is on disk, and as its report in markdown otherwise. The
/// conversation is a transcript tab like the session's own, which this
/// module doesn't know: `makeConversation` makes it.
@MainActor
struct DocumentBodyFactory {
    /// A transcript tab for the conversation at a URL, titled.
    let makeConversation: @MainActor (URL, String) -> NSViewController

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
                    return makeConversation(url, DocumentHeader(document).title)
                }
            }
            return MarkdownDocumentViewController(markdown: DocumentMarkdown.markdown(for: document.content))
        case .search, .web, .taskList, .news, .commandOutput, .compactionSummary, .other:
            return MarkdownDocumentViewController(markdown: DocumentMarkdown.markdown(for: document.content))
        }
    }
}
