import AppKit

/// Leading slot inside a history row. Reserves the same 16pt square the
/// fixed rows + folder headers use for their SF Symbol, so the title
/// column lines up across heterogeneous rows.
///
/// Precedence: unread wins over running. An unfocused session with
/// something the user hasn't seen (a finished turn, or a permission card
/// awaiting approval) shows the dot even mid-turn — "needs you" outranks
/// "busy". They never render simultaneously.
final class SidebarStatusIndicatorView: NSView {

    /// Diameter of the unread dot.
    static let unreadDotSize: CGFloat = 6

    enum State: Equatable {
        case none
        case running
        case unread
    }

    private(set) var state: State = .none
    private let dots = SidebarLoadingDotsView(
        frame: CGRect(
            x: 0, y: 0,
            width: SidebarLayout.iconSlotWidth,
            height: SidebarLayout.iconSlotWidth))
    private let unreadDot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        dots.translatesAutoresizingMaskIntoConstraints = false
        dots.isHidden = true
        addSubview(dots)

        unreadDot.wantsLayer = true
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        unreadDot.isHidden = true
        unreadDot.layer?.cornerRadius = Self.unreadDotSize / 2
        addSubview(unreadDot)
        applyUnreadColor()

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SidebarLayout.iconSlotWidth),
            heightAnchor.constraint(equalToConstant: SidebarLayout.iconSlotWidth),

            dots.leadingAnchor.constraint(equalTo: leadingAnchor),
            dots.trailingAnchor.constraint(equalTo: trailingAnchor),
            dots.topAnchor.constraint(equalTo: topAnchor),
            dots.bottomAnchor.constraint(equalTo: bottomAnchor),

            unreadDot.centerXAnchor.constraint(equalTo: centerXAnchor),
            unreadDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: Self.unreadDotSize),
            unreadDot.heightAnchor.constraint(equalToConstant: Self.unreadDotSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func update(isRunning: Bool, hasUnread: Bool) {
        let newState: State
        if hasUnread {
            newState = .unread
        } else if isRunning {
            newState = .running
        } else {
            newState = .none
        }
        guard newState != state else { return }
        state = newState
        dots.isHidden = newState != .running
        unreadDot.isHidden = newState != .unread
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyUnreadColor()
    }

    private func applyUnreadColor() {
        var resolved: CGColor = NSColor.controlAccentColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.cgColor
        }
        unreadDot.layer?.backgroundColor = resolved
    }
}
