import Foundation

public enum Message2Result: JSONParseable, UnknownStrippable {
    case errorDuringExecution(ErrorDuringExecution)
    case success(Success)
    case unknown(name: String, raw: [String: Any])
}
