import Foundation

public struct ErrorDuringExecutionPermissionDenialsToolInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let allowedPrompts: [AllowedPrompts]?
    public let command: String?
    public let description: String?
    public let filePath: String?
    public let newString: String?
    public let oldString: String?
    public let plan: String?
    public let planFilePath: String?
    public let replaceAll: Bool?
    public let timeout: Int?
}
