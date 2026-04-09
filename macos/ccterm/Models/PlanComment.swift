import Foundation

struct PlanComment: Identifiable, Codable {
    let id: UUID
    var text: String
    let createdAt: Date
    var selectionRange: SelectionRange?

    var isInline: Bool { selectionRange != nil }

    struct SelectionRange: Identifiable, Codable {
        let id: UUID
        let startOffset: Int
        let endOffset: Int
        let selectedText: String

        init(id: UUID = UUID(), startOffset: Int, endOffset: Int, selectedText: String) {
            self.id = id
            self.startOffset = startOffset
            self.endOffset = endOffset
            self.selectedText = selectedText
        }
    }

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), selectionRange: SelectionRange? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.selectionRange = selectionRange
    }
}
