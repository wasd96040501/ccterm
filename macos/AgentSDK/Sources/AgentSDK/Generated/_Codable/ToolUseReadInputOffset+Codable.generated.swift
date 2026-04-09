import Foundation

extension ToolUseReadInputOffset {
    public init(json: Any) throws {
        if let v = json as? String {
            self = .string(v)
        } else if let v = json as? Int {
            self = .integer(v)
        } else {
            self = .other(json)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .string(let v): return v
        case .integer(let v): return v
        case .other(let v): return v
        }
    }
}

extension ToolUseReadInputOffset {
    public func toTypedJSON() -> Any {
        switch self {
        case .string(let v): return v
        case .integer(let v): return v
        case .other(let v): return v
        }
    }
}
