import Foundation

extension ObjectEdit {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectEdit")
        self._raw = r.dict
        self.filePath = r.string("file_path", alt: "filePath")
        self.newString = r.string("new_string", alt: "newString")
        self.oldString = r.string("old_string", alt: "oldString")
        self.originalFile = r.string("original_file", alt: "originalFile")
        self.replaceAll = r.bool("replace_all", alt: "replaceAll")
        self.structuredPatch = try? r.decodeArrayIfPresent("structured_patch", alt: "structuredPatch")
        self.userModified = r.bool("user_modified", alt: "userModified")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectEdit {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = filePath { d["file_path"] = v }
        if let v = newString { d["new_string"] = v }
        if let v = oldString { d["old_string"] = v }
        if let v = originalFile { d["original_file"] = v }
        if let v = replaceAll { d["replace_all"] = v }
        if let v = structuredPatch { d["structured_patch"] = v.map { $0.toTypedJSON() } }
        if let v = userModified { d["user_modified"] = v }
        return d
    }
}
