import AgentSDK
import Foundation

/// A session directory laid out the way the CLI writes one, in a unique temp
/// directory — synthetic rows only, never real transcripts.
@MainActor
final class SessionDirectoryFixture {
    /// Resolved (`/private/var/…`): that is the form the directory's listing
    /// reports, and `resolvingSymlinksInPath()` would strip the prefix instead.
    let root: URL

    var directory: SessionDirectory { SessionDirectory(url: root) }

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let resolved = realpath(directory.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    /// Writes `lines` as a file at `relative`, optionally dated.
    func write(_ relative: String, _ lines: [String], modified: TimeInterval? = nil) throws {
        let url = url(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        if let modified {
            let date = Date(timeIntervalSince1970: modified)
            try FileManager.default.setAttributes(
                [.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
        }
    }

    // MARK: - Rows

    static func user(_ uuid: String, parent: String? = nil, cwd: String = "/x/repo", _ text: String = "hi") -> String {
        row([
            "type": "user", "uuid": uuid, "parentUuid": parent.map { $0 as Any } ?? NSNull(), "sessionId": "s",
            "cwd": cwd,
            "message": ["role": "user", "content": text],
        ])
    }

    static func assistant(_ uuid: String, parent: String?, _ text: String) -> String {
        row([
            "type": "assistant", "uuid": uuid, "parentUuid": parent.map { $0 as Any } ?? NSNull(), "sessionId": "s",
            "message": [
                "id": "m-\(uuid)", "model": "m", "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    static func customTitle(_ title: String) -> String {
        row(["type": "custom-title", "customTitle": title, "sessionId": "s"])
    }

    static func aiTitle(_ title: String) -> String {
        row(["type": "ai-title", "aiTitle": title, "sessionId": "s"])
    }

    static func lastPrompt(_ prompt: String) -> String {
        row(["type": "last-prompt", "lastPrompt": prompt, "sessionId": "s"])
    }

    static func row(_ fields: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
