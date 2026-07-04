import Foundation

extension SessionHistory {

    public enum Order: Sendable {
        case forward
        case reverse
    }

    /// Streams the session's history JSONL in the requested order, decoded
    /// and — for `.reverse` — tool-result-paired inside the SDK.
    ///
    /// Batches are shaped by the reader's I/O buffer, not by an argument:
    /// each yield carries every message decoded from the current chunk so
    /// the caller merges naturally by iterating. Consumers cancel by
    /// cancelling the `Task` that pulls the stream — the producer task's
    /// `onTermination` closes the file handle.
    ///
    /// Off-main by construction: the producer runs inside `Task.detached`
    /// so file I/O, JSON decode, and reverse tool-result pairing never
    /// touch the main thread. The main-thread consumer receives ready-made
    /// `[Message2]` batches via the AsyncThrowingStream's producer→consumer
    /// hop.
    public static func load(
        id: String,
        order: Order = .reverse
    ) -> AsyncThrowingStream<[Message2], Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    guard let url = findSessionFile(sessionId: id) else {
                        continuation.finish()
                        return
                    }
                    switch order {
                    case .forward:
                        try streamForward(url: url, into: continuation)
                    case .reverse:
                        try streamReverse(url: url, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Forward

    private static func streamForward(
        url: URL,
        into continuation: AsyncThrowingStream<[Message2], Error>.Continuation
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let resolver = Message2Resolver()
        let chunk = 64 * 1024
        var carry = Data()

        while true {
            if Task.isCancelled { return }
            let bytes = try handle.read(upToCount: chunk) ?? Data()
            if bytes.isEmpty {
                if !carry.isEmpty, let m = decodeLine(carry, resolver: resolver) {
                    continuation.yield([m])
                }
                return
            }
            carry.append(bytes)
            var batch: [Message2] = []
            while let nl = carry.firstIndex(of: 0x0A) {
                let line = carry[carry.startIndex..<nl]
                carry.removeSubrange(carry.startIndex...nl)
                if line.isEmpty { continue }
                if let m = decodeLine(line, resolver: resolver) { batch.append(m) }
            }
            if !batch.isEmpty { continuation.yield(batch) }
        }
    }

    // MARK: - Reverse (with cross-batch tool_result pairing)

    private static func streamReverse(
        url: URL,
        into continuation: AsyncThrowingStream<[Message2], Error>.Continuation
    ) throws {
        let reader = try _ReverseLineReader(url: url)
        let batchPairer = _ReverseBatchPairer()

        while true {
            if Task.isCancelled { return }
            let lines = reader.popChunk()
            if lines.isEmpty { break }

            // Decode in document order (oldest→newest) so a resolver keeps
            // its tool_use → tool_result pairing correct for the pairs
            // that live inside this chunk.
            let ordered = lines.reversed()
            let resolver = Message2Resolver()
            var decoded: [Message2] = []
            decoded.reserveCapacity(ordered.count)
            for line in ordered {
                if let m = decodeLine(line, resolver: resolver) {
                    decoded.append(m)
                }
            }

            let emit = batchPairer.consume(decoded)
            if !emit.isEmpty {
                // Reverse to newest→oldest for the caller — SDK contract:
                // reverse order yields newest first within each batch.
                continuation.yield(emit.reversed())
            }
        }

        // Drain: any orphan tool_result that never found its tool_use above
        // the file top gets emitted as-is (don't drop silently).
        let tail = batchPairer.drain()
        if !tail.isEmpty {
            continuation.yield(tail.reversed())
        }
    }

    // MARK: - Line decode

    private static func decodeLine(_ bytes: Data, resolver: Message2Resolver) -> Message2? {
        guard let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let m = try? resolver.resolve(json)
        else {
            return nil
        }
        return m
    }

    private static func decodeLine<S: StringProtocol>(_ s: S, resolver: Message2Resolver) -> Message2? {
        guard let data = String(s).data(using: .utf8) else { return nil }
        return decodeLine(data, resolver: resolver)
    }
}

// MARK: - Internal reverse reader (SDK-owned copy)

/// Chunk-at-a-time reverse reader. Emits ~64 KB of complete lines (oldest
/// at end, newest at start) per `popChunk()`; returns empty at file top.
///
/// Kept internal to the SDK — the app-side `ReverseLineReader` is retained
/// separately for the old bridge/pipeline path per the refactor rule
/// "keep old code intact." When that path retires, this becomes the sole
/// implementation.
private final class _ReverseLineReader {

    private let handle: FileHandle
    private let chunkSize: Int
    private var cursor: Int
    private var carry: [UInt8] = []  // partial-line bytes above the chunk boundary

    init(url: URL, chunkSize: Int = 64 * 1024) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.chunkSize = chunkSize
        cursor = Int(try handle.seekToEnd())
    }

    deinit { try? handle.close() }

    /// Pop one chunk's worth of complete lines, newest-first (i.e. the
    /// order they appear in the tail-to-head byte walk). Empty result
    /// means the file top has been consumed.
    func popChunk() -> [String] {
        var out: [String] = []
        if cursor == 0, carry.isEmpty { return out }

        // Read the next older chunk (or the whole remainder at the top).
        let take = min(chunkSize, cursor)
        let from = cursor - take
        var bytes: [UInt8] = []
        do {
            try handle.seek(toOffset: UInt64(from))
            let data = try handle.read(upToCount: take) ?? Data()
            bytes = [UInt8](data)
            cursor = from
        } catch {
            cursor = 0
        }

        // Prepend to carry: `carry` held a partial line's tail from last
        // pop; the new chunk sits before it in file order.
        var buffer = bytes + carry
        carry = []

        // Walk newest-first: find last `\n`, everything after it is a
        // complete line (unless we're at the top and there's no leading
        // `\n`, in which case the head is also a complete line).
        while let nl = buffer.lastIndex(of: 0x0A) {
            let lineBytes = buffer[(nl + 1)...]
            let s = String(decoding: lineBytes, as: UTF8.self)
            buffer.removeLast(buffer.count - nl)
            if !s.isEmpty { out.append(s) }
        }

        // At file top: whatever's left in buffer is the first line.
        if cursor == 0 {
            let s = String(decoding: buffer, as: UTF8.self)
            if !s.isEmpty { out.append(s) }
            buffer = []
        } else {
            // Not at top: the leading bytes might be a partial line whose
            // head lives in the older chunk — carry them across.
            carry = buffer
        }

        return out
    }
}

// MARK: - Reverse pairing buffer

/// Buffers orphan `tool_result` user messages found while walking backward
/// (they arrive before their `tool_use` sibling) and releases them once
/// the matching `tool_use` shows up in a later (older) batch.
private final class _ReverseBatchPairer {

    private var withheld: [String: [Message2]] = [:]  // key = tool_use_id, values in doc order
    private var withheldOrder: [String] = []  // preserve first-seen doc order at re-emit

    /// Consume one decoded batch (document order oldest→newest) and
    /// return the batch to emit (still oldest→newest). Any orphan
    /// tool_result is stored until its tool_use is seen; any tool_use
    /// seen unlocks matching withheld results, which then interleave
    /// naturally into the emit list.
    func consume(_ batch: [Message2]) -> [Message2] {
        // Index tool_use ids present in this batch (assistant messages
        // whose content contains a tool_use).
        var thisBatchToolUseIds: Set<String> = []
        for m in batch {
            if case .assistant(let a) = m, let blocks = a.message?.content {
                for block in blocks {
                    if case .toolUse(let use) = block, let id = use.id {
                        thisBatchToolUseIds.insert(id)
                    }
                }
            }
        }

        var emit: [Message2] = []
        emit.reserveCapacity(batch.count)

        for m in batch {
            // If this is a user message carrying an orphan tool_result,
            // withhold when the pairing tool_use is not present here.
            if case .user(let u) = m, let toolUseId = u.toolResultUseId {
                if thisBatchToolUseIds.contains(toolUseId) {
                    emit.append(m)
                } else {
                    if withheld[toolUseId] == nil {
                        withheld[toolUseId] = []
                        withheldOrder.append(toolUseId)
                    }
                    withheld[toolUseId]?.append(m)
                }
                continue
            }
            emit.append(m)

            // If this batch introduces a tool_use whose result was
            // previously withheld, splice the withheld results in.
            if case .assistant(let a) = m, let blocks = a.message?.content {
                for block in blocks {
                    if case .toolUse(let use) = block,
                        let id = use.id,
                        let held = withheld.removeValue(forKey: id)
                    {
                        if let idx = withheldOrder.firstIndex(of: id) {
                            withheldOrder.remove(at: idx)
                        }
                        emit.append(contentsOf: held)
                    }
                }
            }
        }

        return emit
    }

    /// Called at file top: return everything still withheld (an orphan
    /// tool_result whose tool_use never appeared). Preserves first-seen
    /// doc order so the caller can emit deterministically.
    func drain() -> [Message2] {
        var out: [Message2] = []
        for key in withheldOrder {
            if let held = withheld.removeValue(forKey: key) {
                out.append(contentsOf: held)
            }
        }
        withheldOrder.removeAll()
        return out
    }
}

// MARK: - Message2User tool_result helper

extension Message2User {
    /// The `tool_use_id` of the first tool_result block in this user's
    /// message content, or `nil` if none. Used by the reverse pairer.
    fileprivate var toolResultUseId: String? {
        guard case .array(let items) = message?.content else { return nil }
        for item in items {
            if case .toolResult(let r) = item, let id = r.toolUseId {
                return id
            }
        }
        return nil
    }
}
