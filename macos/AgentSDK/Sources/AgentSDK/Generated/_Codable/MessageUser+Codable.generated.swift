import Foundation

extension MessageUser {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "MessageUser")
        self._raw = r.dict
        self.message = r.decodeIfPresent("message")
        self.timestamp = r.string("timestamp")
        self.toolUseResult = r.string("tool_use_result", alt: "toolUseResult")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension MessageUser {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = message { d["message"] = v.toTypedJSON() }
        if let v = timestamp { d["timestamp"] = v }
        if let v = toolUseResult { d["tool_use_result"] = v }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}
