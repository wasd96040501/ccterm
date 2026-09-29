import Foundation

/// The markdown of a document that is words rather than code — a search, a
/// page fetched, an agent's report, the task list (a `- [x]` checklist as it
/// stood after that call), a task's news, a command's output, a
/// compaction's summary, any other call. TranscriptKit sets it, so find,
/// selection and copy work in it as in a reply.
nonisolated enum DocumentMarkdown {
    static func markdown(for content: DocumentContent) -> String {
        ""
    }
}
