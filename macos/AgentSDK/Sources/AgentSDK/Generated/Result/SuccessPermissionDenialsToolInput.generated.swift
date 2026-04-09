import Foundation

public struct SuccessPermissionDenialsToolInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: String?
    public let filePath: String?
    public let plan: String?
    public let planFilePath: String?
}
