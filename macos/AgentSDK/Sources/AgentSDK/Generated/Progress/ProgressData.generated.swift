import Foundation

public enum ProgressData: JSONParseable, UnknownStrippable {
    case agentProgress(AgentProgress)
    case bashProgress(BashProgress)
    case hookProgress(HookProgress)
    case queryUpdate(QueryUpdate)
    case searchResultsReceived(SearchResultsReceived)
    case waitingForTask(WaitingForTask)
    case unknown(name: String, raw: [String: Any])
}
