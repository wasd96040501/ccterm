import Foundation

extension ContentBashInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ContentBashInput")
        self._raw = r.dict
        self.command = r.string("command")
        self.context = r.int("context")
        self.description = r.string("description")
        self.outputMode = r.string("output_mode")
        self.path = r.string("path")
        self.pattern = r.string("pattern")
        self.timeout = r.int("timeout")
    }

    public func toJSON() -> Any { _raw }
}

extension ContentBashInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = command { d["command"] = v }
        if let v = context { d["context"] = v }
        if let v = description { d["description"] = v }
        if let v = outputMode { d["output_mode"] = v }
        if let v = path { d["path"] = v }
        if let v = pattern { d["pattern"] = v }
        if let v = timeout { d["timeout"] = v }
        return d
    }
}
