import AppKit
import Foundation

/// Render-ready block. `id` is stable identity for diffing — caller assigns.
struct Block: Identifiable, Equatable {
    let id: UUID
    let kind: Kind

    enum Kind: Equatable {
        case heading(String)
        case paragraph(String)
    }
}

/// Centralized typography. Add new visual variants here only.
enum BlockStyle {
    static let headingFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let paragraphFont = NSFont.systemFont(ofSize: 14, weight: .regular)

    /// Vertical padding above/below each block's text within its row.
    static let blockVerticalPadding: CGFloat = 4
    /// Horizontal padding inside the row.
    static let blockHorizontalPadding: CGFloat = 16

    static func attributed(for block: Block) -> NSAttributedString {
        switch block.kind {
        case .heading(let text):
            return NSAttributedString(string: text, attributes: [
                .font: headingFont,
                .foregroundColor: NSColor.labelColor,
            ])
        case .paragraph(let text):
            return NSAttributedString(string: text, attributes: [
                .font: paragraphFont,
                .foregroundColor: NSColor.labelColor,
            ])
        }
    }
}
