import Foundation

public struct RateLimitEvent: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let rateLimitInfo: RateLimitInfo?
    public let sessionId: String?
    public let uuid: String?
}
