/// What the demo can do to its list: one entry per item on the checklist in
/// CLAUDE.md.
enum DemoScenario: CaseIterable {

    /// Append rows while the viewport follows the tail, like a chat.
    case stream

    /// Grow the last row a little on every tick, like streaming text.
    case growLastRow

    /// Expand and collapse a row the reader clicks, anchored on it (A2).
    case toggleClicked

    /// Insert and remove rows above the viewport while the reader reads.
    case churnAbove

    /// Animate the sidebar open and closed: an animated width change.
    case toggleSidebar

    /// Load 10 000 rows.
    case loadLarge

    /// Scroll to the top, animated, from anywhere.
    case scrollToTop
}
