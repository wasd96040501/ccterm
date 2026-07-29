import Foundation

/// Observes display-side events of a `TranscriptView`.
///
/// Every requirement has a default no-op implementation; conform and
/// implement only what the host cares about.
@MainActor
public protocol TranscriptViewDelegate: AnyObject {

    /// A link inside a rendered row was activated.
    func transcriptView(_ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int)
}

extension TranscriptViewDelegate {

    public func transcriptView(
        _ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int
    ) {}
}
