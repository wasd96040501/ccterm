import Foundation

public struct ApiError: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let cause: Cause?
    public let cwd: String?
    public let entrypoint: String?
    public let error: ApiErrorError?
    public let gitBranch: String?
    public let isSidechain: Bool?
    public let level: String?
    public let maxRetries: Int?
    public let parentUuid: String?
    public let retryAttempt: Int?
    public let retryInMs: Double?
    public let sessionId: String?
    public let slug: String?
    public let timestamp: String?
    public let userType: String?
    public let uuid: String?
    public let version: String?
}
