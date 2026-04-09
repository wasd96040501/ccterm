import Foundation

extension RateLimitInfo {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "RateLimitInfo")
        self._raw = r.dict
        self.isUsingOverage = r.bool("is_using_overage", alt: "isUsingOverage")
        self.overageDisabledReason = r.string("overage_disabled_reason", alt: "overageDisabledReason")
        self.overageStatus = r.string("overage_status", alt: "overageStatus")
        self.rateLimitType = r.string("rate_limit_type", alt: "rateLimitType")
        self.resetsAt = r.int("resets_at", alt: "resetsAt")
        self.status = r.string("status")
    }

    public func toJSON() -> Any { _raw }
}

extension RateLimitInfo {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = isUsingOverage { d["is_using_overage"] = v }
        if let v = overageDisabledReason { d["overage_disabled_reason"] = v }
        if let v = overageStatus { d["overage_status"] = v }
        if let v = rateLimitType { d["rate_limit_type"] = v }
        if let v = resetsAt { d["resets_at"] = v }
        if let v = status { d["status"] = v }
        return d
    }
}
