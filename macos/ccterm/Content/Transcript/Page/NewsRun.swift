import Foundation

/// Consecutive task news with nothing visible between them: one row that
/// expands into its lines, as a tool run does
/// (design/transcript/04-background.md "Consecutive news is one row").
nonisolated struct NewsRun: Sendable, Equatable, Identifiable {
    let id: String
    /// Never empty.
    var news: [TaskNews]
    /// The collapsed row; for one piece of news, that news' own line.
    var line: WorkLine

    var isSingle: Bool { news.count == 1 }
}
