import Foundation

extension Routing {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Routing")
        self._raw = r.dict
        self.content = r.string("content")
        self.sender = r.string("sender")
        self.senderColor = r.string("sender_color", alt: "senderColor")
        self.summary = r.string("summary")
        self.target = r.string("target")
        self.targetColor = r.string("target_color", alt: "targetColor")
    }

    public func toJSON() -> Any { _raw }
}

extension Routing {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = content { d["content"] = v }
        if let v = sender { d["sender"] = v }
        if let v = senderColor { d["sender_color"] = v }
        if let v = summary { d["summary"] = v }
        if let v = target { d["target"] = v }
        if let v = targetColor { d["target_color"] = v }
        return d
    }
}
