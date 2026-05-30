import Foundation

extension StreamContentBlockDelta {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "StreamContentBlockDelta")
        self._raw = r.dict
        self.delta = r.rawDict("delta")
        self.index = r.int("index")
    }

    public func toJSON() -> Any { _raw }
}

extension StreamContentBlockDelta {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = delta { d["delta"] = v }
        if let v = index { d["index"] = v }
        return d
    }
}
