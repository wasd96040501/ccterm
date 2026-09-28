import Foundation

public struct LegacyRateLimitEvent: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let rateLimitInfo: LegacyRateLimitInfo?
    public let sessionId: String?
    public let uuid: String?
}
