import Foundation

extension ObjectGlob {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectGlob")
        self._raw = r.dict
        self.durationMs = r.int("duration_ms", alt: "durationMs")
        self.filenames = r.stringArray("filenames")
        self.numFiles = r.int("num_files", alt: "numFiles")
        self.truncated = r.bool("truncated")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectGlob {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = durationMs { d["duration_ms"] = v }
        if let v = filenames { d["filenames"] = v }
        if let v = numFiles { d["num_files"] = v }
        if let v = truncated { d["truncated"] = v }
        return d
    }
}
