import Foundation

extension Plugins {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Plugins")
        self._raw = r.dict
        self.name = r.string("name")
        self.path = r.string("path")
    }

    public func toJSON() -> Any { _raw }
}

extension Plugins {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = name { d["name"] = v }
        if let v = path { d["path"] = v }
        return d
    }
}
