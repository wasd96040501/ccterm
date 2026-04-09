import Foundation

extension ToolUseCronCreateInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseCronCreateInput")
        self._raw = r.dict
        self.cron = r.string("cron")
        self.prompt = r.string("prompt")
        self.recurring = r.bool("recurring")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseCronCreateInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = cron { d["cron"] = v }
        if let v = prompt { d["prompt"] = v }
        if let v = recurring { d["recurring"] = v }
        return d
    }
}
