import Foundation

/// Token accounting for a single conversational turn (one user send → the
/// CLI's `.result`). Tracks only the **fresh** input tokens and the output
/// tokens — cache-creation / cache-read tokens are deliberately excluded so
/// the number reads as "what this turn actually cost to process", not the
/// (much larger) re-sent context.
///
/// A turn produces several assistant inferences; `SessionRuntime` sums one
/// `TurnTokenUsage` per CLI message into the turn total. Updated live from the
/// partial-message stream (`message_start` / `message_delta` usage) and
/// reconciled against each finalized `.assistant` envelope.
struct TurnTokenUsage: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int

    static let zero = TurnTokenUsage(inputTokens: 0, outputTokens: 0)

    var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 }

    static func + (lhs: TurnTokenUsage, rhs: TurnTokenUsage) -> TurnTokenUsage {
        TurnTokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens)
    }

    /// Compact "↑in ↓out" label, e.g. `↑1.2k ↓340`. Returns `nil` when empty so
    /// callers can omit the surface entirely before any tokens are counted.
    var compactLabel: String? {
        guard !isEmpty else { return nil }
        return "↑\(Self.abbreviate(inputTokens)) ↓\(Self.abbreviate(outputTokens))"
    }

    /// `1234 → "1.2k"`, `999 → "999"`, `1_500_000 → "1.5M"`. Whole-number
    /// values under 1000 print verbatim; larger ones get one decimal of k / M.
    static func abbreviate(_ n: Int) -> String {
        switch n {
        case ..<0:
            return "0"
        case 0..<1000:
            return "\(n)"
        case 1000..<1_000_000:
            return trimmedDecimal(Double(n) / 1000) + "k"
        default:
            return trimmedDecimal(Double(n) / 1_000_000) + "M"
        }
    }

    private static func trimmedDecimal(_ v: Double) -> String {
        // One decimal place, but drop a trailing ".0" so "2.0k" reads "2k".
        let rounded = (v * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }
}
