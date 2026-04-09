import Foundation

extension MessageAssistantMessageContent {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unknown", raw: [:]); return
        }
        guard let tag = dict["name"] as? String else {
            self = .unknown(name: "unknown", raw: dict); return
        }
        switch tag {
        case "Bash":
            let _v: ContentBash = try _jp(dict)
            self = .Bash(_v)
        case "Edit":
            let _v: ContentEdit = try _jp(dict)
            self = .Edit(_v)
        case "Glob":
            let _v: ContentGlob = try _jp(dict)
            self = .Glob(_v)
        case "Grep":
            let _v: ContentGrep = try _jp(dict)
            self = .Grep(_v)
        case "Read":
            let _v: ContentRead = try _jp(dict)
            self = .Read(_v)
        case "ToolSearch":
            let _v: ContentToolSearch = try _jp(dict)
            self = .ToolSearch(_v)
        case "WebFetch":
            let _v: ContentWebFetch = try _jp(dict)
            self = .WebFetch(_v)
        case "WebSearch":
            let _v: ContentWebSearch = try _jp(dict)
            self = .WebSearch(_v)
        case "Write":
            let _v: ContentWrite = try _jp(dict)
            self = .Write(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .Bash(let v): return v.toJSON()
        case .Edit(let v): return v.toJSON()
        case .Glob(let v): return v.toJSON()
        case .Grep(let v): return v.toJSON()
        case .Read(let v): return v.toJSON()
        case .ToolSearch(let v): return v.toJSON()
        case .WebFetch(let v): return v.toJSON()
        case .WebSearch(let v): return v.toJSON()
        case .Write(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension MessageAssistantMessageContent {
    public func strippingUnknown() -> MessageAssistantMessageContent? {
        switch self {
        case .unknown: return nil
        case .Bash(let v): return v.strippingUnknown().map { .Bash($0) }
        case .Edit(let v): return v.strippingUnknown().map { .Edit($0) }
        case .Glob(let v): return v.strippingUnknown().map { .Glob($0) }
        case .Grep(let v): return v.strippingUnknown().map { .Grep($0) }
        case .Read(let v): return v.strippingUnknown().map { .Read($0) }
        case .ToolSearch(let v): return v.strippingUnknown().map { .ToolSearch($0) }
        case .WebFetch(let v): return v.strippingUnknown().map { .WebFetch($0) }
        case .WebSearch(let v): return v.strippingUnknown().map { .WebSearch($0) }
        case .Write(let v): return v.strippingUnknown().map { .Write($0) }
        }
    }
}

extension MessageAssistantMessageContent {
    public func toTypedJSON() -> Any {
        switch self {
        case .Bash(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Bash"
            return d
        case .Edit(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Edit"
            return d
        case .Glob(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Glob"
            return d
        case .Grep(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Grep"
            return d
        case .Read(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Read"
            return d
        case .ToolSearch(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "ToolSearch"
            return d
        case .WebFetch(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "WebFetch"
            return d
        case .WebSearch(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "WebSearch"
            return d
        case .Write(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Write"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}
