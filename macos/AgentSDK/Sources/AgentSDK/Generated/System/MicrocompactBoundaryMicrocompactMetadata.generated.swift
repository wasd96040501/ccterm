import Foundation

public struct MicrocompactBoundaryMicrocompactMetadata: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let clearedAttachmentUuiDs: [Any]?
    public let compactedToolIds: [Any]?
    public let preTokens: Int?
    public let tokensSaved: Int?
    public let trigger: String?
}
