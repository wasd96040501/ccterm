import Foundation

public struct ContentReadInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let filePath: String?
    public let limit: Int?
    public let offset: ContentReadInputOffset?
}
