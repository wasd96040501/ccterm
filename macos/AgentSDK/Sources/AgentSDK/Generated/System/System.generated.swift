import Foundation

public enum System: JSONParseable, UnknownStrippable {
    case apiError(ApiError)
    case compactBoundary(CompactBoundary)
    case informational(Informational)
    case `init`(Init)
    case localCommand(LocalCommand)
    case microcompactBoundary(MicrocompactBoundary)
    case status(SystemStatus)
    case taskNotification(TaskNotification)
    case taskProgress(TaskProgress)
    case taskStarted(TaskStarted)
    case turnDuration(TurnDuration)
    case unknown(name: String, raw: [String: Any])
}
