import Foundation

extension MessageUserMessage {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "MessageUserMessage")
        self._raw = r.dict
        self.content = try? r.decodeArrayIfPresent("content")
        self.role = r.string("role")
    }

    public func toJSON() -> Any { _raw }
}

extension MessageUserMessage {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = content { d["content"] = v.map { $0.toTypedJSON() } }
        if let v = role { d["role"] = v }
        return d
    }
}
