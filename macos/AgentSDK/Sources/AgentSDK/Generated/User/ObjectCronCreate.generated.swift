import Foundation

public struct ObjectCronCreate: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let durable: Bool?
    public let humanSchedule: String?
    public let id: String?
    public let recurring: Bool?
}
