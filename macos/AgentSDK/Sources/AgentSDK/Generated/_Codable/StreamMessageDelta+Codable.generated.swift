import Foundation

extension StreamMessageDelta {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "StreamMessageDelta")
        self._raw = r.dict
        self.contextManagement = r.rawDict("context_management")
        self.delta = r.rawDict("delta")
        self.usage = r.rawDict("usage")
    }

    public func toJSON() -> Any { _raw }
}

extension StreamMessageDelta {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = contextManagement { d["context_management"] = v }
        if let v = delta { d["delta"] = v }
        if let v = usage { d["usage"] = v }
        return d
    }
}
