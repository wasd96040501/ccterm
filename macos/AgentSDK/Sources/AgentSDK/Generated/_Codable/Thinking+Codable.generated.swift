import Foundation

extension Thinking {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Thinking")
        self._raw = r.dict
        self.signature = r.string("signature")
        self.thinking = r.string("thinking")
    }

    public func toJSON() -> Any { _raw }
}

extension Thinking {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = signature { d["signature"] = v }
        if let v = thinking { d["thinking"] = v }
        return d
    }
}
