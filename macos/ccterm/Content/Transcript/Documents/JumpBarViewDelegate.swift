import AppKit

@MainActor
protocol JumpBarViewDelegate: AnyObject {
    /// *Show in Transcript* was pressed.
    func jumpBarViewShowInTranscript(_ jumpBar: JumpBarView)
}
