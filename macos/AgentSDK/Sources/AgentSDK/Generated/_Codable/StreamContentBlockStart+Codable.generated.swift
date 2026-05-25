import Foundation

extension StreamContentBlockStart {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "StreamContentBlockStart")
        self._raw = r.dict
        self.contentBlock = r.rawDict("content_block")
        self.index = r.int("index")
    }

    public func toJSON() -> Any { _raw }
}

extension StreamContentBlockStart {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = contentBlock { d["content_block"] = v }
        if let v = index { d["index"] = v }
        return d
    }
}
