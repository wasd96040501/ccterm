import Foundation

extension ObjectTaskOutput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectTaskOutput")
        self._raw = r.dict
        self.retrievalStatus = r.string("retrieval_status")
        self.task = r.decodeIfPresent("task")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectTaskOutput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = retrievalStatus { d["retrieval_status"] = v }
        if let v = task { d["task"] = v.toTypedJSON() }
        return d
    }
}
