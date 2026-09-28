import Foundation
import os

/// Mirrors every protocol line, both directions, into
/// `<directory>/<session id>.jsonl` (``SessionConfiguration/messageExportDirectory``).
///
/// Lines seen before the session id is known are held and flushed into the
/// first file, or on ``close()`` into `unidentified-<uuid>.jsonl` when the
/// id never arrived. Export is best-effort: I/O failures are ignored.
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
            write(s.held + [line], to: s.handle)
            s.held.removeAll()
        }
    }

    func close() {
        state.withLock { s in
            if !s.held.isEmpty {
                s.handle = s.handle ?? open("unidentified-\(UUID().uuidString.lowercased())")
                write(s.held, to: s.handle)
                s.held.removeAll()
            }
            try? s.handle?.close()
            s.handle = nil
        }
    }

    private func write(_ lines: [Data], to handle: FileHandle?) {
        for line in lines {
            var data = line
            data.append(UInt8(ascii: "\n"))
            try? handle?.write(contentsOf: data)
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
