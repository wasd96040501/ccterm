import Foundation

public enum Message2: JSONParseable, UnknownStrippable {
    case assistant(Message2Assistant)
    case customTitle(CustomTitle)
    case fileHistorySnapshot(FileHistorySnapshot)
    case lastPrompt(LastPrompt)
    case progress(Message2Progress)
    case promptSuggestion(PromptSuggestion)
    case queueOperation(QueueOperation)
    case rateLimitEvent(RateLimitEvent)
    case result(Message2Result)
    case system(System)
    case user(Message2User)
    case worktreeState(WorktreeState)
    case unknown(name: String, raw: [String: Any])
}
