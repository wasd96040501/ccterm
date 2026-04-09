import Foundation

public struct SuccessPermissionDenials: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let toolInput: SuccessPermissionDenialsToolInput?
    public let toolName: String?
    public let toolUseId: String?
}
