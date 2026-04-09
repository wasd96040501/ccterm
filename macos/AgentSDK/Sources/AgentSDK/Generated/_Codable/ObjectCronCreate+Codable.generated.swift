import Foundation

extension ObjectCronCreate {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectCronCreate")
        self._raw = r.dict
        self.durable = r.bool("durable")
        self.humanSchedule = r.string("human_schedule", alt: "humanSchedule")
        self.id = r.string("id")
        self.recurring = r.bool("recurring")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectCronCreate {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = durable { d["durable"] = v }
        if let v = humanSchedule { d["human_schedule"] = v }
        if let v = id { d["id"] = v }
        if let v = recurring { d["recurring"] = v }
        return d
    }
}
