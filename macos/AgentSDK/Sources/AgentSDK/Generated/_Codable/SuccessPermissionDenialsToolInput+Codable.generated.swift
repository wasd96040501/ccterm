import Foundation

extension SuccessPermissionDenialsToolInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "SuccessPermissionDenialsToolInput")
        self._raw = r.dict
        self.content = r.string("content")
        self.filePath = r.string("file_path", alt: "filePath")
        self.plan = r.string("plan")
        self.planFilePath = r.string("plan_file_path", alt: "planFilePath")
    }

    public func toJSON() -> Any { _raw }
}

extension SuccessPermissionDenialsToolInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = content { d["content"] = v }
        if let v = filePath { d["file_path"] = v }
        if let v = plan { d["plan"] = v }
        if let v = planFilePath { d["plan_file_path"] = v }
        return d
    }
}
