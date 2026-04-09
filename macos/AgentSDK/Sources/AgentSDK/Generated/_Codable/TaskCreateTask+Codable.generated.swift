import Foundation

extension TaskCreateTask {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TaskCreateTask")
        self._raw = r.dict
        self.id = r.string("id")
        self.subject = r.string("subject")
    }

    public func toJSON() -> Any { _raw }
}

extension TaskCreateTask {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = id { d["id"] = v }
        if let v = subject { d["subject"] = v }
        return d
    }
}
