import Foundation

extension AllowedPrompts {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "AllowedPrompts")
        self._raw = r.dict
        self.prompt = r.string("prompt")
        self.tool = r.string("tool")
    }

    public func toJSON() -> Any { _raw }
}

extension AllowedPrompts {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = prompt { d["prompt"] = v }
        if let v = tool { d["tool"] = v }
        return d
    }
}
