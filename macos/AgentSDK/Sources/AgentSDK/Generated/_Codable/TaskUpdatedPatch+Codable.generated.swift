import Foundation

extension TaskUpdatedPatch {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TaskUpdatedPatch")
        self._raw = r.dict
        self.endTime = r.double("end_time", alt: "endTime")
        self.outputFile = r.string("output_file", alt: "outputFile")
        self.status = r.string("status")
        self.summary = r.string("summary")
    }

    public func toJSON() -> Any { _raw }
}

extension TaskUpdatedPatch {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = endTime { d["end_time"] = v }
        if let v = outputFile { d["output_file"] = v }
        if let v = status { d["status"] = v }
        if let v = summary { d["summary"] = v }
        return d
    }
}
