import Foundation

extension ObjectWrite {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectWrite")
        self._raw = r.dict
        self.content = r.string("content")
        self.filePath = r.string("file_path", alt: "filePath")
        self.originalFile = r.string("original_file", alt: "originalFile")
        self.structuredPatch = try? r.decodeArrayIfPresent("structured_patch", alt: "structuredPatch")
        self.`type` = r.string("type")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectWrite {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = content { d["content"] = v }
        if let v = filePath { d["file_path"] = v }
        if let v = originalFile { d["original_file"] = v }
        if let v = structuredPatch { d["structured_patch"] = v.map { $0.toTypedJSON() } }
        if let v = `type` { d["type"] = v }
        return d
    }
}
