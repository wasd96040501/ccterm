import Foundation

extension CompactBoundaryCompactMetadata {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "CompactBoundaryCompactMetadata")
        self._raw = r.dict
        self.preCompactDiscoveredTools = r.stringArray("pre_compact_discovered_tools", alt: "preCompactDiscoveredTools")
        self.preTokens = r.int("pre_tokens", alt: "preTokens")
        self.trigger = r.string("trigger")
    }

    public func toJSON() -> Any { _raw }
}

extension CompactBoundaryCompactMetadata {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = preCompactDiscoveredTools { d["pre_compact_discovered_tools"] = v }
        if let v = preTokens { d["pre_tokens"] = v }
        if let v = trigger { d["trigger"] = v }
        return d
    }
}
