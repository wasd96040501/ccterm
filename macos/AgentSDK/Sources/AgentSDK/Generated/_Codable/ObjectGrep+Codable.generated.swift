import Foundation

extension ObjectGrep {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectGrep")
        self._raw = r.dict
        self.appliedLimit = r.int("applied_limit", alt: "appliedLimit")
        self.appliedOffset = r.int("applied_offset", alt: "appliedOffset")
        self.content = r.string("content")
        self.filenames = r.stringArray("filenames")
        self.mode = r.string("mode")
        self.numFiles = r.int("num_files", alt: "numFiles")
        self.numLines = r.int("num_lines", alt: "numLines")
        self.numMatches = r.int("num_matches", alt: "numMatches")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectGrep {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = appliedLimit { d["applied_limit"] = v }
        if let v = appliedOffset { d["applied_offset"] = v }
        if let v = content { d["content"] = v }
        if let v = filenames { d["filenames"] = v }
        if let v = mode { d["mode"] = v }
        if let v = numFiles { d["num_files"] = v }
        if let v = numLines { d["num_lines"] = v }
        if let v = numMatches { d["num_matches"] = v }
        return d
    }
}
