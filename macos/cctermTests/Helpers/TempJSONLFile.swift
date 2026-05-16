import Foundation

/// Writes a JSONL string to a unique tmp file and removes it on teardown.
/// Each test gets its own filename (UUID-suffixed), so parallel test
/// processes never share paths.
struct TempJSONLFile {
    let url: URL

    init(_ lines: [String]) throws {
        let dir = FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent("ccterm-test-\(UUID().uuidString).jsonl")
        let payload = lines.joined(separator: "\n") + "\n"
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
