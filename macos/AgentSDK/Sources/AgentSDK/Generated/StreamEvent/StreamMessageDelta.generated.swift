import Foundation

public struct StreamMessageDelta: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let contextManagement: [String: Any]?
    public let delta: [String: Any]?
    public let usage: [String: Any]?
}
