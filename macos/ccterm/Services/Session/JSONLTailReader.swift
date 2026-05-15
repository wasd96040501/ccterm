import Foundation

/// 字节级 tail 读取器 —— 从文件末尾向前 chunk 读，拼出 ≥ N 行 JSONL，返回
/// **forward** 顺序（最早→最新）。用于两段式 `loadHistory` 的 Phase A：让
/// UI 在几十 ms 内就能看到末尾若干条消息，而不是阻塞全量 parse。
///
/// 文件路径下的 JSONL 约定：每行一条 JSON 记录、`\n` 分隔、末尾可能有空行。
/// 中间 `\n` 只作行分隔符（json payload 不含裸 `\n`），所以仅用 `\n` 切行即可。
enum JSONLTailReader {

    struct Result {
        /// `targetLines` 行 JSONL，forward 顺序（最早→最新）。
        /// 空数组可能性：文件空 / 只含空行。
        let lines: [String]
        /// 这批 lines 在文件中的起始字节偏移。Phase B 按 `[0, offset)` 读 prefix
        /// bytes；若返回值 == 0 意味着尾部已涵盖全文件（没有 prefix 要读）。
        let tailStartByteOffset: Int
    }

    enum ReaderError: Error, LocalizedError {
        case fileNotFound(URL)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let url): return "JSONL file not found: \(url.path)"
            }
        }
    }

    /// 读文件末尾 ≥ `targetLines` 行 JSONL。
    ///
    /// - Parameters:
    ///   - url: JSONL 文件路径
    ///   - targetLines: 期望行数下限。实际返回可能略多（一个 chunk 边界可能跨多行）。
    ///   - maxBytes: 字节读取上限。避免文件末尾有超大单行把整个文件读完。
    ///     默认 1 MiB 对典型 CLI JSONL 足够。
    /// - Returns: `Result(lines, tailStartByteOffset)`
    /// - Throws: `ReaderError.fileNotFound` 或 底层 I/O 错误
    static func readTail(
        url: URL,
        targetLines: Int,
        maxBytes: Int = 1 << 20
    ) throws -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReaderError.fileNotFound(url)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = Int(try handle.seekToEnd())
        if fileSize == 0 {
            return Result(lines: [], tailStartByteOffset: 0)
        }

        let chunkSize = 64 * 1024
        var bufferBytes: [UInt8] = []
        var readSoFar = 0
        var currentOffset = fileSize
        // 每次读 chunk，拼到 bufferBytes 前面。
        // 直到 累计字节 >= maxBytes 或 覆盖全文件 或 足够 targetLines 行。
        while currentOffset > 0, readSoFar < maxBytes {
            let take = min(chunkSize, currentOffset, maxBytes - readSoFar)
            let readFrom = currentOffset - take
            try handle.seek(toOffset: UInt64(readFrom))
            let chunk = try handle.read(upToCount: take) ?? Data()
            bufferBytes = Array(chunk) + bufferBytes
            readSoFar += chunk.count
            currentOffset = readFrom

            // Count complete lines in bufferBytes. A "complete line" ends with \n
            // OR (for the very last line at EOF) has no trailing \n — we still
            // count the tail piece once currentOffset == 0 (whole file read).
            let lineCount = countNewlines(bufferBytes)
            if currentOffset > 0, lineCount > targetLines {
                // 已有足够行（多出一行用作边界保护——第一个 `\n` 之前的残缺段丢掉）。
                break
            }
            if currentOffset == 0 { break }
        }

        // 切行：按 \n 拆。`split` 会丢掉空 segment，但我们要区分「末尾空行」和「文件中间
        // 空行」——JSONL 中间不会有空行，末尾可能有。所以用 components(separatedBy:)。
        let text = String(decoding: bufferBytes, as: UTF8.self)
        let all = text.components(separatedBy: "\n")

        // all 的第一项可能是"残段"（被 chunk 边界切掉头）。如果 currentOffset > 0，
        // 说明我们没有读到文件起始，第一个 piece 可能是上半行残件 —— 丢掉。
        let usable: [String]
        var droppedBytes: Int
        if currentOffset > 0 {
            let firstPiece = all[0]
            droppedBytes = firstPiece.utf8.count + (all.count > 1 ? 1 : 0)
            usable = Array(all.dropFirst())
        } else {
            droppedBytes = 0
            usable = all
        }

        // 过滤空行（末尾 "\n\n" 产出的 empty segment）。
        let nonEmpty = usable.filter { !$0.isEmpty }

        // 截取末尾 targetLines 条（可能少于 target，如果 buffer 里就这么多）。
        let tail: [String]
        if nonEmpty.count > targetLines {
            tail = Array(nonEmpty.suffix(targetLines))
            // startByteOffset = fileSize - (最后 targetLines 行的字节数 + 中间分隔 \n)
            let tailBytes = tail.reduce(0) { $0 + $1.utf8.count + 1 }
            return Result(
                lines: tail,
                tailStartByteOffset: max(0, fileSize - tailBytes))
        } else {
            tail = nonEmpty
            // buffer 里只有这些行。startByteOffset = currentOffset（未读部分的字节数）
            // 加上已被 `droppedBytes` 丢掉的那部分残段。
            return Result(
                lines: tail,
                tailStartByteOffset: currentOffset + droppedBytes)
        }
    }

    /// 快速计算 byte 数组中 `\n` 的个数（不分配 String）。
    private static func countNewlines(_ bytes: [UInt8]) -> Int {
        var n = 0
        for b in bytes where b == 0x0A { n += 1 }
        return n
    }
}
