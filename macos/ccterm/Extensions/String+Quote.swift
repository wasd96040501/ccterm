import Foundation

extension String {
    /// Trim leading/trailing whitespace and collapse consecutive blank lines into a single newline.
    var trimmedForQuote: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse runs of 2+ newlines (with optional spaces/tabs between) into a single newline
        return trimmed.replacingOccurrences(
            of: "[ \\t]*\\n([ \\t]*\\n)+",
            with: "\n",
            options: .regularExpression
        )
    }
}
