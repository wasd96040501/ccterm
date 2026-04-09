import Foundation
import Observation

@Observable
@MainActor
final class PlanCommentStore {
    private(set) var comments: [PlanComment] = []
    let permissionRequestId: String

    var hasComments: Bool { !comments.isEmpty }

    var inlineComments: [PlanComment] {
        comments.filter(\.isInline).sorted { ($0.selectionRange?.startOffset ?? 0) < ($1.selectionRange?.startOffset ?? 0) }
    }

    var globalComments: [PlanComment] {
        comments.filter { !$0.isInline }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Callback when comments change (used to push to React).
    var onCommentsChanged: (([PlanComment]) -> Void)?

    init(permissionRequestId: String) {
        self.permissionRequestId = permissionRequestId
        load()
    }

    // MARK: - CRUD

    func addInlineComment(text: String, range: PlanComment.SelectionRange) {
        let comment = PlanComment(text: text, selectionRange: range)
        comments.append(comment)
        persist()
        onCommentsChanged?(comments)
    }

    func addGlobalComment(text: String) {
        let comment = PlanComment(text: text)
        comments.append(comment)
        persist()
        onCommentsChanged?(comments)
    }

    func updateComment(id: UUID, text: String) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[index].text = text
        persist()
        onCommentsChanged?(comments)
    }

    func removeComment(id: UUID) {
        comments.removeAll { $0.id == id }
        persist()
        onCommentsChanged?(comments)
    }

    func removeAll() {
        comments.removeAll()
        persist()
        onCommentsChanged?(comments)
    }

    // MARK: - Feedback Assembly

    func assembleFeedback() -> String {
        let inlines = inlineComments
        let globals = globalComments
        let hasInline = !inlines.isEmpty
        let hasGlobal = !globals.isEmpty

        if hasInline && !hasGlobal {
            return inlines.map { formatInline($0) }.joined(separator: "\n\n")
        }
        if !hasInline && hasGlobal {
            return globals.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        }

        var parts: [String] = ["## Review Comments"]
        if hasInline {
            parts.append("\n### Inline Comments\n")
            parts.append(contentsOf: inlines.map { formatInline($0) })
        }
        if hasGlobal {
            parts.append("\n### General Comments\n")
            parts.append(contentsOf: globals.enumerated().map { "\($0.offset + 1). \($0.element.text)" })
        }
        return parts.joined(separator: "\n")
    }

    private func formatInline(_ c: PlanComment) -> String {
        "> \"\(c.selectionRange?.selectedText ?? "")\"\n\(c.text)"
    }

    // MARK: - Persistence

    private var udKey: String { "planComments_\(permissionRequestId)" }

    private func persist() {
        guard let data = try? JSONEncoder().encode(comments) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let saved = try? JSONDecoder().decode([PlanComment].self, from: data) else { return }
        comments = saved
    }

    static func cleanup(permissionRequestId: String) {
        UserDefaults.standard.removeObject(forKey: "planComments_\(permissionRequestId)")
    }
}
