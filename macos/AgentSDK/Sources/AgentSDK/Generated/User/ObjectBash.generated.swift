import Foundation

public struct ObjectBash: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let assistantAutoBackgrounded: Bool?
    public let backgroundTaskId: String?
    public let backgroundedByUser: Bool?
    public let interrupted: Bool?
    public let isImage: Bool?
    public let noOutputExpected: Bool?
    public let persistedOutputPath: String?
    public let persistedOutputSize: Int?
    public let returnCodeInterpretation: String?
    public let stderr: String?
    public let stdout: String?
    public let tokenSaverOutput: String?
}
