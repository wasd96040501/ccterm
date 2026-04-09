import Foundation

extension Headers {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Headers")
        self._raw = r.dict
        self.cfCacheStatus = r.string("cf-cache-status")
        self.cfRay = r.string("cf-ray")
        self.connection = r.string("connection")
        self.contentLength = r.string("content-length")
        self.contentSecurityPolicy = r.string("content-security-policy")
        self.contentType = r.string("content-type")
        self.date = r.string("date")
        self.server = r.string("server")
        self.xRobotsTag = r.string("x-robots-tag")
    }

    public func toJSON() -> Any { _raw }
}

extension Headers {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = cfCacheStatus { d["cf-cache-status"] = v }
        if let v = cfRay { d["cf-ray"] = v }
        if let v = connection { d["connection"] = v }
        if let v = contentLength { d["content-length"] = v }
        if let v = contentSecurityPolicy { d["content-security-policy"] = v }
        if let v = contentType { d["content-type"] = v }
        if let v = date { d["date"] = v }
        if let v = server { d["server"] = v }
        if let v = xRobotsTag { d["x-robots-tag"] = v }
        return d
    }
}
