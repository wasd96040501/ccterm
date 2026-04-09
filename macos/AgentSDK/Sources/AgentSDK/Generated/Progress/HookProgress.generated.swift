import Foundation

public struct HookProgress: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let command: String?
    public let hookEvent: String?
    public let hookName: String?
}
