import Foundation

public struct CompactBoundaryCompactMetadata: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let preCompactDiscoveredTools: [String]?
    public let preTokens: Int?
    public let trigger: String?
}
