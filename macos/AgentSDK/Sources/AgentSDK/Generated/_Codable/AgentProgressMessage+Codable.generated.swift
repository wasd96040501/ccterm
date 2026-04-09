import Foundation

extension AgentProgressMessage {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unknown", raw: [:]); return
        }
        guard let tag = dict["type"] as? String else {
            self = .unknown(name: "unknown", raw: dict); return
        }
        switch tag {
        case "assistant":
            let _v: MessageAssistant = try _jp(dict)
            self = .assistant(_v)
        case "user":
            let _v: MessageUser = try _jp(dict)
            self = .user(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .assistant(let v): return v.toJSON()
        case .user(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension AgentProgressMessage {
    public func strippingUnknown() -> AgentProgressMessage? {
        switch self {
        case .unknown: return nil
        case .assistant(let v): return v.strippingUnknown().map { .assistant($0) }
        case .user(let v): return v.strippingUnknown().map { .user($0) }
        }
    }
}

extension AgentProgressMessage {
    public func toTypedJSON() -> Any {
        switch self {
        case .assistant(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "assistant"
            return d
        case .user(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "user"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}
