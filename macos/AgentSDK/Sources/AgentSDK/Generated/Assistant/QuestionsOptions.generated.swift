import Foundation

public struct QuestionsOptions: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let description: String?
    public let label: String?
    public let preview: String?
}
