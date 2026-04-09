import Foundation

extension Message2Result {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unknown", raw: [:]); return
        }
        guard let tag = dict["subtype"] as? String else {
            self = .unknown(name: "unknown", raw: dict); return
        }
        switch tag {
        case "error_during_execution":
            let _v: ErrorDuringExecution = try _jp(dict)
            self = .errorDuringExecution(_v)
        case "success":
            let _v: Success = try _jp(dict)
            self = .success(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .errorDuringExecution(let v): return v.toJSON()
        case .success(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension Message2Result {
    public func strippingUnknown() -> Message2Result? {
        switch self {
        case .unknown: return nil
        case .errorDuringExecution(let v): return v.strippingUnknown().map { .errorDuringExecution($0) }
        case .success(let v): return v.strippingUnknown().map { .success($0) }
        }
    }
}

extension Message2Result {
    public func toTypedJSON() -> Any {
        switch self {
        case .errorDuringExecution(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "error_during_execution"
            return d
        case .success(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "success"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}
