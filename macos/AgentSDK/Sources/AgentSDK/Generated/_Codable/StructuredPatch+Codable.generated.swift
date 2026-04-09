import Foundation

extension StructuredPatch {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "StructuredPatch")
        self._raw = r.dict
        self.lines = r.stringArray("lines")
        self.newLines = r.int("new_lines", alt: "newLines")
        self.newStart = r.int("new_start", alt: "newStart")
        self.oldLines = r.int("old_lines", alt: "oldLines")
        self.oldStart = r.int("old_start", alt: "oldStart")
    }

    public func toJSON() -> Any { _raw }
}

extension StructuredPatch {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = lines { d["lines"] = v }
        if let v = newLines { d["new_lines"] = v }
        if let v = newStart { d["new_start"] = v }
        if let v = oldLines { d["old_lines"] = v }
        if let v = oldStart { d["old_start"] = v }
        return d
    }
}
