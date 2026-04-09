import Foundation

extension Message2UserMessage {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Message2UserMessage")
        self._raw = r.dict
        self.content = r.decodeIfPresent("content")
        self.role = r.string("role")
    }

    public func toJSON() -> Any { _raw }
}

extension Message2UserMessage {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = content { d["content"] = v.toTypedJSON() }
        if let v = role { d["role"] = v }
        return d
    }
}
