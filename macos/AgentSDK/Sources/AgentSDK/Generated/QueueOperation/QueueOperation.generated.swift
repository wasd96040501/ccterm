import Foundation

public enum QueueOperation: JSONParseable, UnknownStrippable {
    case dequeue(Dequeue)
    case enqueue(Enqueue)
    case remove(Dequeue)
    case unknown(name: String, raw: [String: Any])
}
