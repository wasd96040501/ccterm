import AppKit

/// The composer's action button (design 08 *The action button*): AppKit's
/// round button (the `.circular` bezel) at the large control size. Send —
/// `arrow.up` — is tinted with the accent (primary tint prominence; before
/// macOS 26, the accent as its bezel colour), which the system drops while it
/// is disabled or its window isn't key. Stop — `stop.fill` — is the plain
/// bezel. Its look, its press, its disabled state and its size are the
/// system's.
@MainActor
final class ComposerActionButton: NSButton {
    enum Kind {
        case send
        case stop
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        title = ""
        controlSize = .large
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: kind == .send ? "arrow.up" : "stop.fill", accessibilityDescription: nil)
        bezelStyle = .circular
        if kind == .send {
            if #available(macOS 26, *) {
                tintProminence = .primary
            } else {
                bezelColor = .controlAccentColor
            }
        }
        translatesAutoresizingMaskIntoConstraints = false
        // A circle: as wide as the control size makes it tall.
        widthAnchor.constraint(equalTo: heightAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
