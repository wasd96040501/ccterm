import Foundation

public enum JSONParseError: Error, CustomStringConvertible {
    case missingField(String, in: String)
    case typeMismatch(expected: String, in: String)

    public var description: String {
        switch self {
        case .missingField(let field, let structName):
            return "Missing required field '\(field)' in \(structName)"
        case .typeMismatch(let expected, let context):
            return "Type mismatch: expected \(expected) in \(context)"
        }
    }
}
