import Foundation
import os

/// Mirrors every protocol line, both directions, into
/// `<directory>/<session id>.jsonl` (``SessionConfiguration/messageExportDirectory``).
///
/// Lines seen before the session id is known are held and flushed into the
/// first file. Export is best-effort: I/O failures are ignored.
final class MessageExporter: Sendable {
    private let directory: URL
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var sessionID: String?
        var handle: FileHandle?
        var held: [Data] = []
    }

    init(directory: URL) {
        self.directory = directory
    }

    func append(_ line: Data, sessionID: String?) {
        state.withLock { s in
            guard let sessionID else {
                s.held.append(line)
                return
            }
            if s.sessionID != sessionID {
                try? s.handle?.close()
                s.handle = open(sessionID)
                s.sessionID = sessionID
            }
            for pending in s.held + [line] {
                var data = pending
                data.append(UInt8(ascii: "\n"))
                try? s.handle?.write(contentsOf: data)
            }
            s.held.removeAll()
        }
    }

    func close() {
        state.withLock { s in
            try? s.handle?.close()
            s.handle = nil
        }
    }

    private func open(_ sessionID: String) -> FileHandle? {
        let url = directory.appendingPathComponent("\(sessionID).jsonl")
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }
}
