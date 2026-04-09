import Foundation

extension ToolUseGrepInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseGrepInput")
        self._raw = r.dict
        self.A = r.int("-a", alt: "-A")
        self.B = r.int("-b", alt: "-B")
        self.C = r.int("-c", alt: "-C")
        self.I = r.bool("-i")
        self.N = r.bool("-n")
        self.context = r.int("context")
        self.filePath = r.string("file_path", alt: "filePath")
        self.glob = r.string("glob")
        self.headLimit = r.int("head_limit")
        self.limit = r.int("limit")
        self.offset = r.int("offset")
        self.outputMode = r.string("output_mode")
        self.path = r.string("path")
        self.pattern = r.string("pattern")
        self.query = r.string("query")
        self.`type` = r.string("type")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseGrepInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = A { d["-a"] = v }
        if let v = B { d["-b"] = v }
        if let v = C { d["-c"] = v }
        if let v = I { d["-i"] = v }
        if let v = N { d["-n"] = v }
        if let v = context { d["context"] = v }
        if let v = filePath { d["file_path"] = v }
        if let v = glob { d["glob"] = v }
        if let v = headLimit { d["head_limit"] = v }
        if let v = limit { d["limit"] = v }
        if let v = offset { d["offset"] = v }
        if let v = outputMode { d["output_mode"] = v }
        if let v = path { d["path"] = v }
        if let v = pattern { d["pattern"] = v }
        if let v = query { d["query"] = v }
        if let v = `type` { d["type"] = v }
        return d
    }
}
