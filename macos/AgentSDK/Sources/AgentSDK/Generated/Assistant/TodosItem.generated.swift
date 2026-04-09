import Foundation

public struct TodosItem: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let activeForm: String?
    public let content: String?
    public let status: String?
}
