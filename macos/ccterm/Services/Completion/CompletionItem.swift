import Cocoa

protocol CompletionItem {
    var displayText: String { get }
    var displayIcon: NSImage? { get }
    var displayDetail: String? { get }
    var displayBadge: String? { get }
}

extension CompletionItem {
    var displayBadge: String? { nil }
}
