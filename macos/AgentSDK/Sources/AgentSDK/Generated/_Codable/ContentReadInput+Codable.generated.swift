import Foundation

extension ContentReadInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ContentReadInput")
        self._raw = r.dict
        self.filePath = r.string("file_path", alt: "filePath")
        self.limit = r.int("limit")
        self.offset = r.decodeIfPresent("offset")
    }

    public func toJSON() -> Any { _raw }
}

extension ContentReadInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = filePath { d["file_path"] = v }
        if let v = limit { d["limit"] = v }
        if let v = offset { d["offset"] = v.toTypedJSON() }
        return d
    }
}
