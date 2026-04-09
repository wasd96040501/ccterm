import Foundation

public struct ErrorDuringExecutionPermissionDenials: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let toolInput: ErrorDuringExecutionPermissionDenialsToolInput?
    public let toolName: String?
    public let toolUseId: String?
}
