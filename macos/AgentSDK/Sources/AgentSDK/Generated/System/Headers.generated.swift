import Foundation

public struct Headers: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let cfCacheStatus: String?
    public let cfRay: String?
    public let connection: String?
    public let contentLength: String?
    public let contentSecurityPolicy: String?
    public let contentType: String?
    public let date: String?
    public let server: String?
    public let xRobotsTag: String?
}
