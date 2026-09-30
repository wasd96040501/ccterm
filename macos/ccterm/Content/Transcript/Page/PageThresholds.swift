import Foundation

/// The numbers the page decides by, each read off 1 500 real transcripts
/// (design/transcript/research/findings.md) rather than chosen. One place, so
/// a threshold is changed with its evidence in view.
nonisolated enum PageThresholds {
    /// Items an expanded run lists before *Show N more*: 98.3 % of runs fit.
    static let listedItems = 12
    /// Files a clause names before it counts them: > 95 % of runs change two
    /// or fewer.
    static let namedFiles = 2
    /// Clauses in a run's sentence before *and N more*: runs use two kinds of
    /// tool at p95, four at p99.
    static let clauses = 3
    /// A run's wall time is shown from here: the median run takes 8 s, so
    /// about half the rows carry no clock.
    static let shownDuration: TimeInterval = 10
    /// A pause this long between two rows gets a time divider — Messages'
    /// rule for timestamps.
    static let pause: TimeInterval = 60 * 60
}
