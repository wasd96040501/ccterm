import Foundation

extension Source {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Source")
        self._raw = r.dict
        self.data = r.string("data")
        self.mediaType = r.string("media_type")
        self.`type` = r.string("type")
    }

    public func toJSON() -> Any { _raw }
}

extension Source {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = data { d["data"] = v }
        if let v = mediaType { d["media_type"] = v }
        if let v = `type` { d["type"] = v }
        return d
    }
}
