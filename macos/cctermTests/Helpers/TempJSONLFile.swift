import Foundation

/// Writes transcript lines to a unique tmp file and removes it on teardown.
/// Each test gets its own filename (UUID-suffixed), so parallel test
/// processes never share paths.
///
/// Rows are linked the way the CLI writes a transcript: each row that has a
/// `uuid` but no `parentUuid` gets the previous row's uuid as its parent, so
/// `AgentSDK.Transcript` resolves the file as one conversation chain.
struct TempJSONLFile {
    let url: URL

    init(_ lines: [String]) throws {
        let dir = FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent("ccterm-test-\(UUID().uuidString).jsonl")
        let payload = Self.chained(lines).joined(separator: "\n") + "\n"
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    static func chained(_ lines: [String]) -> [String] {
        var parent: String?
        return lines.map { line in
            guard
                var row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                let uuid = row["uuid"] as? String
            else { return line }
            if row["parentUuid"] == nil { row["parentUuid"] = parent ?? NSNull() }
            parent = uuid
            let data = try! JSONSerialization.data(withJSONObject: row)
            return String(data: data, encoding: .utf8)!
        }
    }
}
