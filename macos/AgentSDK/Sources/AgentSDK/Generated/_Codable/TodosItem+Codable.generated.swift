import Foundation

extension TodosItem {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TodosItem")
        self._raw = r.dict
        self.activeForm = r.string("active_form", alt: "activeForm")
        self.content = r.string("content")
        self.status = r.string("status")
    }

    public func toJSON() -> Any { _raw }
}

extension TodosItem {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = activeForm { d["active_form"] = v }
        if let v = content { d["content"] = v }
        if let v = status { d["status"] = v }
        return d
    }
}
