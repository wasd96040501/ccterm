import Foundation

public enum Results: JSONParseable {
    case string(String)
    case object(ResultsObject)
    case other(Any)
}
