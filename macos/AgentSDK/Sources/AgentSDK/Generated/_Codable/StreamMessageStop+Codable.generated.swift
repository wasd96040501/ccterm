import Foundation

extension StreamMessageStop {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "StreamMessageStop")
        self._raw = r.dict
    }

    public func toJSON() -> Any { _raw }
}

extension StreamMessageStop {
    public func toTypedJSON() -> Any {
        return [String: Any]()
    }
}
