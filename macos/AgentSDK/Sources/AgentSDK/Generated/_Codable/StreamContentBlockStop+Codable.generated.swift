import Foundation

extension StreamContentBlockStop {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "StreamContentBlockStop")
        self._raw = r.dict
        self.index = r.int("index")
    }

    public func toJSON() -> Any { _raw }
}

extension StreamContentBlockStop {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = index { d["index"] = v }
        return d
    }
}
