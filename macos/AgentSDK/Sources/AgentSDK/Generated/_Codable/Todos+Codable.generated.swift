import Foundation

extension Todos {
    public init(json: Any) throws {
        if let v = json as? String {
            self = .string(v)
        } else if let v = json as? [Any] {
            self = .array(try v.map { try TodosItem(json: $0) })
        } else {
            self = .other(json)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .string(let v): return v
        case .array(let v): return v.map { $0.toJSON() }
        case .other(let v): return v
        }
    }
}

extension Todos {
    public func toTypedJSON() -> Any {
        switch self {
        case .string(let v): return v
        case .array(let v): return v.map { $0.toTypedJSON() }
        case .other(let v): return v
        }
    }
}
