import Foundation

public struct ObjectWebSearch: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let durationSeconds: Double?
    public let query: String?
    public let results: [Results]?
}
