import CryptoKit
import Foundation

/// Deterministic UUID derivation. Folds a stable coordinate like
/// `(entryId, role, idx, ...)` into a stable UUID for use as `Block.id` and
/// `ToolGroupBlock.Child.id`.
///
/// Why: `Transcript2Coordinator`'s diff, fold-state, selection, and highlight
/// scope are all keyed on `Block.id` / `Child.id`. The same entry must hash
/// to the same UUID across snapshot rebuilds, otherwise (a) incremental diff
/// degrades to remove-all + insert-all, and (b) user-expanded diffs reset.
///
/// Implementation: SHA256(seed) → first 16 bytes → UUID v5/variant. Same seed
/// → same UUID.
enum StableBlockID {
    /// Seed prefix for a tool-use child UUID, shared across the bridge's
    /// status-push paths and `ToolUseToChild` so the same `(prefix, toolUseId)`
    /// coordinate always folds to the same `Child.id`.
    static let toolChildPrefix = "tool"

    /// Folds any list of strings into one stable UUID. The `|` separator is
    /// purely for legibility when inspecting the seed; it doesn't affect
    /// correctness.
    static func derive(_ parts: String...) -> UUID {
        let seed = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}
