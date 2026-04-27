import AppKit
import Foundation

/// Render-ready block. `id` is stable identity for diffing — caller assigns.
struct Block: Identifiable, Equatable {
    let id: UUID
    let kind: Kind

    enum Kind: Equatable {
        case heading(String)
        case paragraph(String)
        case image(NSImage)
    }
}

/// Centralized typography + per-row geometry constants.
///
/// Per-kind attributed builders live here (`headingAttributed` /
/// `paragraphAttributed`). There is no `attributed(for: Block)` —
/// non-text kinds (image / table / tool) cannot be reduced to a single
/// `NSAttributedString`, so the layout pipeline switches on `Block.Kind`
/// directly and dispatches to the right primitive.
enum BlockStyle {
    static let headingFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let paragraphFont = NSFont.systemFont(ofSize: 14, weight: .regular)

    /// Vertical padding above/below each block's content within its row.
    static let blockVerticalPadding: CGFloat = 4
    /// Horizontal padding inside the row.
    static let blockHorizontalPadding: CGFloat = 16

    /// Cap for image height — wide-and-tall sources don't dominate the viewport.
    static let imageMaxHeight: CGFloat = 360

    static func headingAttributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: headingFont,
            .foregroundColor: NSColor.labelColor,
        ])
    }

    static func paragraphAttributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: paragraphFont,
            .foregroundColor: NSColor.labelColor,
        ])
    }
}
