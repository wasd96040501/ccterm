import Foundation

extension ToolUseReadInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseReadInput")
        self._raw = r.dict
        self.filePath = r.string("file_path", alt: "filePath")
        self.limit = r.decodeIfPresent("limit")
        self.offset = r.decodeIfPresent("offset")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseReadInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = filePath { d["file_path"] = v }
        if let v = limit { d["limit"] = v.toTypedJSON() }
        if let v = offset { d["offset"] = v.toTypedJSON() }
        return d
    }
}
