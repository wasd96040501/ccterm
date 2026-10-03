import AppKit

@MainActor
public protocol JumpBarViewDelegate: AnyObject {
    /// *Show in Transcript* was pressed.
    func jumpBarViewDidRequestShowInTranscript(_ jumpBar: JumpBarView)
}
