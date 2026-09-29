/// What a batch holds still on screen (SPEC §6.1).
///
/// `NSTableView` has no counterpart: nothing there says where the viewport goes
/// when rows change. This is how a host chooses, per batch.
public enum Anchoring: Equatable, Sendable {

    /// A1. The tail while the viewport is following it; otherwise the first
    /// visible row, at its current screen position.
    case automatic

    /// A2. Row `row` (pre-batch index), at its current screen position, visible
    /// or not. This is how a host names the row the reader acted on. It
    /// overrides tail following, so the row the reader clicked doesn't move
    /// away from the pointer.
    case row(Int)

    /// A3. The scroll offset itself: `NSTableView`'s behaviour.
    case scrollOffset
}
