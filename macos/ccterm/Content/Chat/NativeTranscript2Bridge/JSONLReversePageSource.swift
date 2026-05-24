import AgentSDK
import Foundation

/// Production `ReversePageSource` over a session's history JSONL.
///
/// Yields the **tail page first** (a byte-level read of the last `tailTarget`
/// lines via `HistoryLoader.parseTail`, so the first screen renders in tens of
/// ms), then walks the prefix `[0, tailStartByteOffset)` toward the file top in
/// `pageSize` chunks (newest chunk first). Each page is **document order**
/// internally; `nil` once the file top is reached.
///
/// All I/O runs inside `nextPage`, which the pipeline calls from its off-main
/// producer task, so parsing never touches the main thread. The internal cursor
/// is mutated only by that single serial caller; `@unchecked Sendable`
/// documents that.
final class JSONLReversePageSource: ReversePageSource, @unchecked Sendable {

    private let url: URL?
    private let tailTarget: Int
    private let pageSize: Int

    private enum Phase {
        case tail
        case prefix
        case done
    }
    private var phase: Phase = .tail
    private var tailStartByteOffset = 0
    /// Prefix chunks in document order; served from the last index down so the
    /// chunk adjacent to the tail emerges first.
    private var prefixPages: [[Message2]] = []
    private var prefixCursor = -1
    /// One-shot guard: the prefix is read + chunked exactly once. Without it,
    /// the cursor reaching `-1` would re-trigger `loadPrefixPages` and loop.
    private var prefixLoaded = false

    init(url: URL?, tailTarget: Int = 80, pageSize: Int = 80) {
        self.url = url
        self.tailTarget = tailTarget
        self.pageSize = pageSize
    }

    func nextPage() async -> [Message2]? {
        switch phase {
        case .tail:
            phase = .prefix
            switch HistoryLoader.parseTail(at: url, targetLines: tailTarget) {
            case .success(let parsed):
                tailStartByteOffset = parsed.tailStartByteOffset
                // Empty tail (missing/empty file) → fall through to prefix,
                // which is also empty, terminating cleanly.
                return parsed.messages.isEmpty ? await nextPage() : parsed.messages
            case .failure:
                phase = .done
                return nil
            }

        case .prefix:
            if !prefixLoaded {
                prefixLoaded = true
                loadPrefixPages()
            }
            guard prefixCursor >= 0 else {
                phase = .done
                return nil
            }
            defer { prefixCursor -= 1 }
            return prefixPages[prefixCursor]

        case .done:
            return nil
        }
    }

    /// Read + chunk the prefix once, on the first prefix `nextPage`.
    private func loadPrefixPages() {
        guard tailStartByteOffset > 0, let url,
            case .success(let prefix) = HistoryLoader.parsePrefix(
                at: url, byteLimit: tailStartByteOffset),
            !prefix.isEmpty
        else {
            prefixPages = []
            prefixCursor = -1
            return
        }
        prefixPages = stride(from: 0, to: prefix.count, by: pageSize).map {
            Array(prefix[$0..<min($0 + pageSize, prefix.count)])
        }
        prefixCursor = prefixPages.count - 1
    }
}
