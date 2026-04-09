import Foundation

extension ObjectExitPlanMode {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectExitPlanMode")
        self._raw = r.dict
        self.filePath = r.string("file_path", alt: "filePath")
        self.isAgent = r.bool("is_agent", alt: "isAgent")
        self.plan = r.string("plan")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectExitPlanMode {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = filePath { d["file_path"] = v }
        if let v = isAgent { d["is_agent"] = v }
        if let v = plan { d["plan"] = v }
        return d
    }
}
