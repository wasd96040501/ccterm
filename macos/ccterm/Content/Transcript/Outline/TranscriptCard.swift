import Foundation

/// A transcript row the app draws itself — a `.view` row's model.
nonisolated enum TranscriptCard: Sendable, Equatable {
    case tools(ToolGroup)
    case notice(TranscriptNotice)
    case command(LocalCommand)
}
