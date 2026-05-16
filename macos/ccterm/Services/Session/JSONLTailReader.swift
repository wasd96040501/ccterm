import Foundation

/// Byte-level tail reader — reads chunks backward from EOF to assemble ≥ N
/// JSONL lines, returned in **forward** order (oldest → newest). Used by
/// `loadHistory` Phase A so the UI can render the last few messages within
/// tens of ms instead of waiting on a full parse.
///
/// JSONL convention: one JSON record per line, `\n` separated, possible
/// trailing blank line. Inner `\n` only acts as line separator (JSON payloads
/// contain no bare `\n`), so splitting on `\n` is sufficient.
enum JSONLTailReader {

    struct Result {
        /// `targetLines` JSONL rows in forward order (oldest → newest).
        /// Empty when the file is empty or only blank lines.
        let lines: [String]
        /// Starting byte offset of these lines in the file. Phase B reads the
        /// prefix `[0, offset)`; offset == 0 means the tail covered the whole
        /// file (no prefix left to read).
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

    /// Read ≥ `targetLines` JSONL lines from the end of the file.
    ///
    /// - Parameters:
    ///   - url: JSONL file path.
    ///   - targetLines: Lower bound on returned line count. Actual count may
    ///     exceed this (chunk boundaries can straddle multiple lines).
    ///   - maxBytes: Byte cap to avoid reading the whole file when a giant
    ///     single line sits at the end. 1 MiB suffices for typical CLI JSONL.
    /// - Returns: `Result(lines, tailStartByteOffset)`
    /// - Throws: `ReaderError.fileNotFound` or underlying I/O errors.
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
        // Read each chunk and prepend it to bufferBytes until we hit maxBytes,
        // cover the whole file, or accumulate enough lines.
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
                // One extra line as boundary guard — the partial fragment
                // before the first `\n` will be dropped.
                break
            }
            if currentOffset == 0 { break }
        }

        // Split on `\n`. `split` drops empty segments, but we need to
        // distinguish "trailing blank line" from "blank in the middle":
        // JSONL has no middle blanks, but may have a trailing one. So use
        // components(separatedBy:).
        let text = String(decoding: bufferBytes, as: UTF8.self)
        let all = text.components(separatedBy: "\n")

        // The first piece may be a fragment cut by a chunk boundary. When
        // currentOffset > 0 we did not reach the file start, so drop the
        // first piece as a likely partial line head.
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

        // Filter blank lines (empty segments produced by trailing "\n\n").
        let nonEmpty = usable.filter { !$0.isEmpty }

        // Take the last targetLines (may be fewer if the buffer holds fewer).
        let tail: [String]
        if nonEmpty.count > targetLines {
            tail = Array(nonEmpty.suffix(targetLines))
            // startByteOffset = fileSize - (bytes of last targetLines + their
            // separating \n).
            let tailBytes = tail.reduce(0) { $0 + $1.utf8.count + 1 }
            return Result(
                lines: tail,
                tailStartByteOffset: max(0, fileSize - tailBytes))
        } else {
            tail = nonEmpty
            // Buffer holds all the lines we have. startByteOffset =
            // currentOffset (unread bytes) plus the fragment we dropped.
            return Result(
                lines: tail,
                tailStartByteOffset: currentOffset + droppedBytes)
        }
    }

    /// Fast count of `\n` bytes in a byte array (no String allocation).
    private static func countNewlines(_ bytes: [UInt8]) -> Int {
        var n = 0
        for b in bytes where b == 0x0A { n += 1 }
        return n
    }
}
