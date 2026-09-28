import Foundation

/// One hunk of a unified diff, as the file-editing tools record it.
public struct DiffHunk: Sendable, Equatable, Decodable {
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    /// Diff lines, each prefixed with `" "`, `"-"` or `"+"`.
    public var lines: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        oldStart = c.lenientInt("oldStart") ?? 0
        oldLines = c.lenientInt("oldLines") ?? 0
        newStart = c.lenientInt("newStart") ?? 0
        newLines = c.lenientInt("newLines") ?? 0
        lines = c.lenient([String].self, "lines") ?? []
    }
}
