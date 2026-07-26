import AppKit

/// One interactive hot zone in content-local coords. Drives both the
/// cursor swap (`resetCursorRects` registers `.pointingHand` over `rect`)
/// and click dispatch (`mouseDown` matches the point against `rect` and
/// runs `action`). `MarkdownBlockView` offsets `rect` by its content
/// origin before either use; a view emits hits in its own content space.
struct InteractiveHit: Sendable {
    let rect: CGRect
    let action: HitAction
}
