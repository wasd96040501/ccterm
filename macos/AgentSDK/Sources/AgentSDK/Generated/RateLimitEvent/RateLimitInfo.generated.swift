import Foundation

public struct RateLimitInfo: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let isUsingOverage: Bool?
    public let overageDisabledReason: String?
    public let overageStatus: String?
    public let rateLimitType: String?
    public let resetsAt: Int?
    public let status: String?
}
