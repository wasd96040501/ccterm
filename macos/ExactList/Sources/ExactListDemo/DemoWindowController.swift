import AppKit

/// The demo window: a sidebar that animates open and closed beside the list (an
/// animated width change), and a toolbar with one button per scenario in
/// `DemoScenario`.
@MainActor
final class DemoWindowController: NSWindowController {

    init() {
        fatalError("unimplemented: demo")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
