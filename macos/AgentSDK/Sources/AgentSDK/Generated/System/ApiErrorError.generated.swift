import Foundation

public struct ApiErrorError: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let cause: Cause?
    public let headers: Headers?
    public let requestId: Any?
    public let status: Int?
}
