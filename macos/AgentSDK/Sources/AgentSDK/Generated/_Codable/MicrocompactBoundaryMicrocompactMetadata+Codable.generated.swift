import Foundation

extension MicrocompactBoundaryMicrocompactMetadata {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "MicrocompactBoundaryMicrocompactMetadata")
        self._raw = r.dict
        self.clearedAttachmentUuiDs = r.rawArray("cleared_attachment_uui_ds", alt: "clearedAttachmentUUIDs")
        self.compactedToolIds = r.rawArray("compacted_tool_ids", alt: "compactedToolIds")
        self.preTokens = r.int("pre_tokens", alt: "preTokens")
        self.tokensSaved = r.int("tokens_saved", alt: "tokensSaved")
        self.trigger = r.string("trigger")
    }

    public func toJSON() -> Any { _raw }
}

extension MicrocompactBoundaryMicrocompactMetadata {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = clearedAttachmentUuiDs { d["cleared_attachment_uui_ds"] = v }
        if let v = compactedToolIds { d["compacted_tool_ids"] = v }
        if let v = preTokens { d["pre_tokens"] = v }
        if let v = tokensSaved { d["tokens_saved"] = v }
        if let v = trigger { d["trigger"] = v }
        return d
    }
}
