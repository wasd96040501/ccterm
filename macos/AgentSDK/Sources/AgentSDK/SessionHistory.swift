import Foundation

public enum SessionHistory {

    /// 在 `~/.claude/projects/` 下递归查找 `<sessionId>.jsonl` 文件。
    public static func findSessionFile(sessionId: String) -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let target = "\(sessionId).jsonl"

        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == target {
                return fileURL
            }
        }
        return nil
    }

    /// 从 JSONL 文件加载所有可解析的消息。
    public static func loadMessages(from fileURL: URL) -> [Message2] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let resolver = Message2Resolver()
        var messages: [Message2] = []
        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = try? resolver.resolve(json) else {
                continue
            }
            messages.append(message)
        }
        return messages
    }

    /// 按 sessionId 查找文件并加载消息。找不到文件返回空数组。
    public static func loadMessages(sessionId: String) -> [Message2] {
        guard let fileURL = findSessionFile(sessionId: sessionId) else {
            return []
        }
        return loadMessages(from: fileURL)
    }
}
