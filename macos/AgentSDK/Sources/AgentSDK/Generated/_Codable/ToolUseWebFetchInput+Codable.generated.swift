import Foundation

extension ToolUseWebFetchInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseWebFetchInput")
        self._raw = r.dict
        self.prompt = r.string("prompt")
        self.url = r.string("url")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseWebFetchInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = prompt { d["prompt"] = v }
        if let v = url { d["url"] = v }
        return d
    }
}
