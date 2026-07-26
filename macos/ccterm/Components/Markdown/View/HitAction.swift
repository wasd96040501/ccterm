import AppKit

/// What clicking an `InteractiveHit` does. Closed enum so
/// `MarkdownBlockView.mouseDown`'s dispatch stays an exhaustive switch.
/// Adding a new interaction = add a case here and a switch arm there.
enum HitAction: Sendable, Equatable {
    /// `.link`-attributed run. The base view opens it via
    /// `NSWorkspace.shared.open`.
    case openURL(URL)
    /// User-bubble chevron — "show me the untruncated message". A host
    /// intent: the base view has nowhere to present a sheet, so it
    /// ignores the action unless the host acts on it.
    case openUserBubbleSheet
    /// User-attachment chip clicked — "enlarge this image". Same
    /// host-intent shape as `openUserBubbleSheet`. The carried `NSImage`
    /// is the exact instance the view's measure holds; `==` falls back
    /// to reference equality through NSObject, which is what hover
    /// matching wants (a view knows which chip is hovered by comparing
    /// the action against its hovered action).
    case openImagePreview(NSImage)
    /// Copy-button click — produced by every `CopyChrome` a measure
    /// emits (code block, diff card). The `id` keys per-button hover +
    /// post-click checkmark feedback so a view with multiple copy
    /// buttons flashes only the clicked icon. `text` is the pasteboard
    /// payload.
    case copy(id: UUID, text: String)
}
