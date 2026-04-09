import Foundation

extension Results {
    public init(json: Any) throws {
        if let v = json as? String {
            self = .string(v)
        } else if let v = json as? [String: Any] {
            self = .object(try ResultsObject(json: v))
        } else {
            self = .other(json)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .string(let v): return v
        case .object(let v): return v.toJSON()
        case .other(let v): return v
        }
    }
}

extension Results {
    public func toTypedJSON() -> Any {
        switch self {
        case .string(let v): return v
        case .object(let v): return v.toTypedJSON()
        case .other(let v): return v
        }
    }
}
