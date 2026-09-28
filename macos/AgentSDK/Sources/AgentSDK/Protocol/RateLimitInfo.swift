import Foundation

/// The account's rate-limit state. Emitted whenever it changes.
public struct RateLimitInfo: Sendable, Equatable {
    /// `allowed`, `allowed_warning`, or `rejected`.
    public var status: String
    public var resetsAt: Date?
    /// `five_hour`, `seven_day`, `seven_day_opus`, `overage`, …
    public var rateLimitType: String?
    /// Fraction of the limit used, 0…1.
    public var utilization: Double?
}

extension RateLimitInfo: Decodable {
    /// Decodes the `rate_limit_event` envelope.
    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: AnyCodingKey.self)
        let c = try outer.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "rate_limit_info")
        self.status = try c.required(String.self, "status")
        self.resetsAt = c.lenient(Double.self, "resetsAt").map { Date(timeIntervalSince1970: $0) }
        self.rateLimitType = c.lenient(String.self, "rateLimitType")
        self.utilization = c.lenient(Double.self, "utilization")
    }
}
