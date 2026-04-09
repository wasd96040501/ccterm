import Foundation

extension Image {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Image")
        self._raw = r.dict
        self.source = r.decodeIfPresent("source")
    }

    public func toJSON() -> Any { _raw }
}

extension Image {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = source { d["source"] = v.toTypedJSON() }
        return d
    }
}
