import Foundation

extension StreamMessageStart {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "StreamMessageStart")
        self._raw = r.dict
        self.message = r.rawDict("message")
    }

    public func toJSON() -> Any { _raw }
}

extension StreamMessageStart {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = message { d["message"] = v }
        return d
    }
}
