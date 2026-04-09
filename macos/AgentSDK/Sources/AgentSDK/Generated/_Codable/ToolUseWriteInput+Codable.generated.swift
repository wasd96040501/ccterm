import Foundation

extension ToolUseWriteInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseWriteInput")
        self._raw = r.dict
        self.content = r.string("content")
        self.filePath = r.string("file_path", alt: "filePath")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseWriteInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = content { d["content"] = v }
        if let v = filePath { d["file_path"] = v }
        return d
    }
}
