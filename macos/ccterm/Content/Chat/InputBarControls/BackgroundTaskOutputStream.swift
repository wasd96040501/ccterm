import Foundation
import Observation

/// Tails the spool file the CLI writes a background bash's stdout/stderr
/// to and exposes the accumulated text as an `@Observable` string. One
/// stream per file path; the popover allocates an instance lazily when
/// the user expands a card and tears it down on collapse.
///
/// File-watching uses a `DispatchSource.makeFileSystemObjectSource` on
/// the file descriptor as the primary signal, with a 1-second timer as
/// a defensive backstop — the CLI writes to a file inside
/// `/private/tmp/claude-501/.../tasks/…`, which historically lives on
/// the same volume the user's home does, but the source is cheap and
/// the timer is the only safe net for the rare cases where the kernel
/// elides a `.write` event (large appends arriving across multiple
/// 4KB pages without a flush).
@Observable
@MainActor
final class BackgroundTaskOutputStream {

    /// Absolute path of the spool file. Used as the canonical identity
    /// for the stream — the popover caches one instance per path.
    let path: String

    /// Accumulated UTF-8 text read from the file so far. Reset whenever
    /// the file shrinks (rotated / truncated upstream), which we detect
    /// by comparing the current size to `bytesRead`.
    private(set) var text: String = ""

    /// True while the underlying file does not (yet) exist. The CLI
    /// allocates the spool file lazily when the bash subprocess writes
    /// its first byte; the UI surfaces a "Waiting for output…" empty
    /// state in this case.
    private(set) var fileMissing: Bool = true

    /// True for the brief window between the popover allocating us and
    /// the first read landing. Allows the UI to render a single-line
    /// progress indicator instead of an empty card.
    private(set) var isStarting: Bool = true

    /// Optional cap on the in-memory buffer. The CLI does not rotate
    /// these files itself (they live across the session), so a stuck
    /// `while true; do echo hi; done` would otherwise eat unbounded
    /// memory. The popover renders the trailing portion only — older
    /// content is dropped from the buffer with a sentinel marker.
    private let maxBytes: Int

    @ObservationIgnored private var fd: Int32 = -1
    @ObservationIgnored private var bytesRead: Int = 0
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var stopped: Bool = false

    init(path: String, maxBytes: Int = 256 * 1024) {
        self.path = path
        self.maxBytes = maxBytes
    }

    deinit {
        // Closing the fd is safe from any thread; the dispatch source
        // holds its own strong reference and runs its cancel handler
        // before releasing the fd.
        let captured = fd
        let s = source
        let t = timer
        if captured >= 0 { close(captured) }
        s?.cancel()
        t?.cancel()
    }

    /// Begin tailing. Idempotent — repeated calls are no-ops.
    func start() {
        guard !stopped, source == nil, timer == nil else { return }
        // Poll every second as a defensive backstop in case the
        // filesystem-event source misses a write. 1s is the smallest
        // interval Apple recommends for cooperatively polling files
        // without burning CPU; the CLI's writes are line-buffered so
        // an extra second of latency past the kernel event is
        // imperceptible.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .seconds(1))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
        pump()
    }

    /// Stop tailing. Called when the card collapses or the popover
    /// dismisses. Frees the fd and the dispatch source; the buffered
    /// text stays observable so a quick re-expand renders the last
    /// known state without flickering through "Waiting for output…".
    func stop() {
        stopped = true
        source?.cancel()
        source = nil
        timer?.cancel()
        timer = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func pump() {
        guard !stopped else { return }
        // First-time setup: try to open the file. The CLI allocates it
        // lazily on first write, so this can fail until something
        // actually executes.
        if fd < 0 {
            let opened = open(path, O_RDONLY | O_NONBLOCK)
            if opened < 0 {
                fileMissing = true
                return
            }
            fd = opened
            fileMissing = false
            armFSSource()
        } else {
            fileMissing = false
        }
        readAvailable()
        isStarting = false
    }

    private func armFSSource() {
        guard fd >= 0, source == nil else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        s.setEventHandler { [weak self] in self?.readAvailable() }
        // Cancel handler intentionally empty — `stop()` closes the fd.
        s.setCancelHandler {}
        s.resume()
        source = s
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        // Stat to detect truncation: if the file shrunk under us, the
        // tail-position seek would land past EOF and read zero bytes
        // until the next write surpasses the old offset — silently
        // dropping output. Better to reset and reread from the top.
        var st = stat()
        if fstat(fd, &st) == 0 {
            if Int(st.st_size) < bytesRead {
                bytesRead = 0
                text = ""
                lseek(fd, 0, SEEK_SET)
            }
        }
        var newBytes = Data()
        let bufSize = 8 * 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                Foundation.read(fd, ptr.baseAddress, bufSize)
            }
            if n <= 0 { break }
            newBytes.append(contentsOf: buf.prefix(n))
            bytesRead += n
        }
        guard !newBytes.isEmpty else { return }
        // Decode lossily so a partial multi-byte UTF-8 codepoint at the
        // tail of one batch doesn't blank the chunk. The next pump cycle
        // includes its bytes naturally.
        let chunk = String(decoding: newBytes, as: UTF8.self)
        if text.count + chunk.count > maxBytes {
            // Drop everything but the tail of (existing + chunk) so the
            // user always sees the most recent output.
            let combined = text + chunk
            let tailStart =
                combined.index(
                    combined.endIndex,
                    offsetBy: -(maxBytes - 256),
                    limitedBy: combined.startIndex
                ) ?? combined.startIndex
            text = "[…earlier output truncated…]\n" + String(combined[tailStart...])
        } else {
            text += chunk
        }
    }
}
