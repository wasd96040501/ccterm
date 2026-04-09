import Foundation

extension ObjectWebFetch {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectWebFetch")
        self._raw = r.dict
        self.bytes = r.int("bytes")
        self.code = r.int("code")
        self.codeText = r.string("code_text", alt: "codeText")
        self.durationMs = r.int("duration_ms", alt: "durationMs")
        self.result = r.string("result")
        self.url = r.string("url")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectWebFetch {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = bytes { d["bytes"] = v }
        if let v = code { d["code"] = v }
        if let v = codeText { d["code_text"] = v }
        if let v = durationMs { d["duration_ms"] = v }
        if let v = result { d["result"] = v }
        if let v = url { d["url"] = v }
        return d
    }
}
