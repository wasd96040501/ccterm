import Foundation

extension Cause {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Cause")
        self._raw = r.dict
        self.code = r.string("code")
        self.errno = r.int("errno")
        self.path = r.string("path")
    }

    public func toJSON() -> Any { _raw }
}

extension Cause {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = code { d["code"] = v }
        if let v = errno { d["errno"] = v }
        if let v = path { d["path"] = v }
        return d
    }
}
