import CryptoKit
import Foundation

/// Deterministic UUID 派生工具。把 `(entryId, role, idx, ...)` 这样的稳定坐标
/// 折成同样稳定的 UUID,用作 `Block.id` 和 `ToolGroupBlock.Child.id`。
///
/// 为什么需要：`Transcript2Coordinator` 的 diff、fold-state、selection、
/// highlight scope 全部 key on `Block.id` / `Child.id`。同一条 entry 在两次
/// snapshot 重建之间必须算出同一个 UUID,否则 (a) 增量 diff 会变成
/// remove-all+insert-all,(b) 用户展开的 diff 会被重置。
///
/// 实现：SHA256(seed) 前 16 字节 → UUID v5/variant。同一 seed → 同一 UUID。
enum StableBlockID {
    /// 折叠任意字符串列表为同一稳定 UUID。用 `|` 做分隔符纯粹是为了
    /// debug 时一眼看出 seed 结构,不影响正确性。
    static func derive(_ parts: String...) -> UUID {
        let seed = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
