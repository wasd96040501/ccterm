import Foundation

extension CustomTitle {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "CustomTitle")
        self._raw = r.dict
        self.customTitle = r.string("custom_title", alt: "customTitle")
        self.sessionId = r.string("session_id", alt: "sessionId")
    }

    public func toJSON() -> Any { _raw }
}

extension CustomTitle {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = customTitle { d["custom_title"] = v }
        if let v = sessionId { d["session_id"] = v }
        return d
    }
}
