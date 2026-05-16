import Foundation

public enum SessionHistory {

    /// Recursively searches `~/.claude/projects/` for `<sessionId>.jsonl`.
    public static func findSessionFile(sessionId: String) -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let target = "\(sessionId).jsonl"

        guard
            let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == target {
                return fileURL
            }
        }
        return nil
    }

    /// Loads every parseable message from a JSONL file.
    public static func loadMessages(from fileURL: URL) -> [Message2] {
        guard let data = try? Data(contentsOf: fileURL),
            let content = String(data: data, encoding: .utf8)
        else {
            return []
        }

        let resolver = Message2Resolver()
        var messages: [Message2] = []
        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                let lineData = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let message = try? resolver.resolve(json)
            else {
                continue
            }
            messages.append(message)
        }
        return messages
    }

    /// Looks up the file for `sessionId` and loads its messages. Returns an empty array if the file is missing.
    public static func loadMessages(sessionId: String) -> [Message2] {
        guard let fileURL = findSessionFile(sessionId: sessionId) else {
            return []
        }
        return loadMessages(from: fileURL)
    }
}
