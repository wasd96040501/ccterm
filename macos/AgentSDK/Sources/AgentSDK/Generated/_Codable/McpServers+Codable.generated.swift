import Foundation

extension McpServers {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "McpServers")
        self._raw = r.dict
        self.name = r.string("name")
        self.status = r.string("status")
    }

    public func toJSON() -> Any { _raw }
}

extension McpServers {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = name { d["name"] = v }
        if let v = status { d["status"] = v }
        return d
    }
}
