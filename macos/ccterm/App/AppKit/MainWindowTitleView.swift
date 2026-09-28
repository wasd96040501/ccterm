import AppKit

/// The main window's title, as Xcode's toolbar shows it: the project's folder
/// icon and name, and under it the project's git branch.
///
/// Not the window's own `title` / `subtitle`: AppKit lays a title out alone
/// (15-point semibold, centred) until a subtitle arrives and then again as two
/// lines (13-point bold over 11-point), in one frame and without animation — and
/// the branch arrives after the name, read off the main thread. So the two lines
/// are always laid out, in the fonts AppKit uses for a title with a subtitle,
/// and the branch fades in where it goes: nothing moves when it arrives.
@MainActor
final class MainWindowTitleView: NSView {

    /// The project's name, or `nil` to show nothing.
    var title: String? {
        didSet {}
    }

    /// The project's branch; `nil` hides it — at once, since what it said
    /// belonged to a folder no longer shown. A branch arriving fades in.
    var subtitle: String? {
        didSet {}
    }

    init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
