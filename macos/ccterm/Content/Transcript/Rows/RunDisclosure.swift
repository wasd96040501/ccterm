import Foundation

/// How much of a run — or of a row of news — the reader has opened. The
/// reader's alone: a run is never expanded for them, and the tab remembers
/// it per run.
nonisolated enum RunDisclosure: Sendable, Equatable {
    case collapsed
    /// The first `CorpusThresholds.listedItems` items, then *Show N more*.
    case expanded
    /// Every item: the reader pressed *Show N more*.
    case showingAll
}
