import Foundation
import AgentSDK

struct MessageEntry: Identifiable {
    let id: UUID
    let message: Message2
    var delivery: DeliveryState?
    var toolResults: [String: ItemToolResult]
}

enum DeliveryState: Equatable {
    case queued
    case inFlight
    case delivered
    case failed(reason: String)
}
