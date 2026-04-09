import Foundation

extension Text {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Text")
        self._raw = r.dict
        self.text = r.string("text")
    }

    public func toJSON() -> Any { _raw }
}

extension Text {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = text { d["text"] = v }
        return d
    }
}
