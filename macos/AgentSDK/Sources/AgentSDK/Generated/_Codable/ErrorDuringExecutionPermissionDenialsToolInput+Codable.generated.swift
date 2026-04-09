import Foundation

extension ErrorDuringExecutionPermissionDenialsToolInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ErrorDuringExecutionPermissionDenialsToolInput")
        self._raw = r.dict
        self.allowedPrompts = try? r.decodeArrayIfPresent("allowed_prompts", alt: "allowedPrompts")
        self.command = r.string("command")
        self.description = r.string("description")
        self.filePath = r.string("file_path", alt: "filePath")
        self.newString = r.string("new_string", alt: "newString")
        self.oldString = r.string("old_string", alt: "oldString")
        self.plan = r.string("plan")
        self.planFilePath = r.string("plan_file_path", alt: "planFilePath")
        self.replaceAll = r.bool("replace_all", alt: "replaceAll")
        self.timeout = r.int("timeout")
    }

    public func toJSON() -> Any { _raw }
}

extension ErrorDuringExecutionPermissionDenialsToolInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = allowedPrompts { d["allowed_prompts"] = v.map { $0.toTypedJSON() } }
        if let v = command { d["command"] = v }
        if let v = description { d["description"] = v }
        if let v = filePath { d["file_path"] = v }
        if let v = newString { d["new_string"] = v }
        if let v = oldString { d["old_string"] = v }
        if let v = plan { d["plan"] = v }
        if let v = planFilePath { d["plan_file_path"] = v }
        if let v = replaceAll { d["replace_all"] = v }
        if let v = timeout { d["timeout"] = v }
        return d
    }
}
