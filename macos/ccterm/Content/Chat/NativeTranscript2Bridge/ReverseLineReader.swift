import Foundation

/// Streaming reverse line reader over a UTF-8 text file. Yields complete lines
/// **newest-first** via repeated `popLine()`, reading fixed-size chunks
/// backward from EOF only as needed and reassembling lines split across a chunk
/// boundary. Returns `nil` once the file top is consumed.
///
/// This replaces the old one-shot tail/prefix split (`JSONLTailReader.readTail`
/// for the last N lines + `HistoryLoader.parsePrefix` reading the entire
/// remainder in a single `read` + parse): the backfill pipeline now pages
/// backward through the whole history off-main with **no monolithic parse and
/// no whole-file buffer** — peak memory is one chunk plus a partial-line carry.
///
/// JSONL convention: one JSON record per line, `\n`-separated, possible
/// trailing blank line. JSON payloads carry no bare `\n`, so splitting on `\n`
/// is sufficient. Blank lines (e.g. a trailing newline) are skipped.
///
/// Not thread-safe; the backfill producer is its only, serial caller.
final class ReverseLineReader {

    private let handle: FileHandle
    private let chunkSize: Int
    /// Lowest byte offset read so far. `buffer` holds the file bytes
    /// `[cursor, cursor + buffer.count)` that have been read but not yet
    /// emitted as lines; everything above has already been returned.
    private var cursor: Int
    private var buffer: [UInt8] = []

    init(url: URL, chunkSize: Int = 64 * 1024) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.chunkSize = chunkSize
        cursor = Int(try handle.seekToEnd())
    }

    deinit { try? handle.close() }

    /// The next complete line below what's already been returned, newest-first.
    /// `nil` at file top. Reads older chunks lazily to complete a line that
    /// straddles a chunk boundary, so no line is ever dropped at the seam.
    func popLine() -> String? {
        while true {
            if let nl = buffer.lastIndex(of: 0x0A) {
                let lineBytes = buffer[(nl + 1)...]
                // Drop the trailing `\n` plus the line we're returning; the
                // remaining head keeps the older bytes for the next pop.
                let emitted = String(decoding: lineBytes, as: UTF8.self)
                buffer.removeLast(buffer.count - nl)
                if emitted.isEmpty { continue }  // blank line (e.g. trailing \n)
                return emitted
            }
            if cursor == 0 {
                // File start reached: the remaining buffer is the first line.
                if buffer.isEmpty { return nil }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer = []
                return line.isEmpty ? nil : line
            }
            readOlderChunk()
        }
    }

    /// Prepend the next older chunk so the line straddling the current head can
    /// complete. On an I/O error, collapse to file top and stop cleanly rather
    /// than spin.
    private func readOlderChunk() {
        let take = min(chunkSize, cursor)
        let from = cursor - take
        do {
            try handle.seek(toOffset: UInt64(from))
            let chunk = try handle.read(upToCount: take) ?? Data()
            buffer.insert(contentsOf: chunk, at: 0)
            cursor = from
        } catch {
            cursor = 0
        }
    }
}
