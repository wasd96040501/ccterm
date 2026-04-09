import Foundation

public class Message2Resolver {

    public init() {}

    private var resolvedToolIndex: [String: ToolUse] = [:]

    public func reset() {
        resolvedToolIndex = [:]
    }

    public func resolve(_ json: Any) throws -> Message2 {
        guard let dict = json as? [String: Any] else {
            return try Message2(json: json)
        }
        var message = try Message2(json: dict)
        buildIndexes(message)
        resolveFields(&message)
        return message
    }

    private func buildIndexes(_ message: Message2) {
        if case .assistant(let _variant) = message {
            if let _nav0 = _variant.message {
                for _item in _nav0.content ?? [] {
                    if case .toolUse(let _toolUse) = _item {
                        if let _k = _toolUse.id {
                            resolvedToolIndex[_k] = _toolUse
                        }
                    }
                }
            }
        }
    }

    private func resolveFields(_ message: inout Message2) {
        if case .user(var _parent) = message {
            if case .object(var _obj)? = _parent.toolUseResult,
               _obj.isUnresolved {
                if let _nav0 = _parent.message {
                    if case .array(let _items)? = _nav0.content {
                        for _item in _items {
                            if case .toolResult(let _result) = _item {
                                if let _lookupKey = _result.toolUseId,
                                   let _origin = resolvedToolIndex[_lookupKey] {
                                    try? _obj.resolve(from: _origin)
                                    _parent.toolUseResult = .object(_obj)
                                    message = .user(_parent)
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
