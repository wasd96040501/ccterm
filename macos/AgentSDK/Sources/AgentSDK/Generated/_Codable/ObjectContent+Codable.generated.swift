import Foundation

extension ObjectContent {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectContent")
        self._raw = r.dict
        self.title = r.string("title")
        self.url = r.string("url")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectContent {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = title { d["title"] = v }
        if let v = url { d["url"] = v }
        return d
    }
}
