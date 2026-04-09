import Foundation

extension ToolUseEditInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseEditInput")
        self._raw = r.dict
        self.filePath = r.string("file_path", alt: "filePath")
        self.newString = r.string("new_string", alt: "newString")
        self.oldString = r.string("old_string", alt: "oldString")
        self.replaceAll = r.bool("replace_all", alt: "replaceAll")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseEditInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = filePath { d["file_path"] = v }
        if let v = newString { d["new_string"] = v }
        if let v = oldString { d["old_string"] = v }
        if let v = replaceAll { d["replace_all"] = v }
        return d
    }
}
