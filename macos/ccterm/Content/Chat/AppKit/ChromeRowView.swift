import AppKit

/// AppKit replacement for `InputBarSessionChrome.swift` (migration plan §4.2).
/// The per-session controls row rendered directly under the input bar pill, at
/// a FIXED 22pt height. An `NSStackView`:
///
/// ```
/// [Permission][BgTask][Todo] ──spacer── [ModelEffort][ContextRing]
/// ```
///
/// with a leading inset of `AttachButtonView.size (32) + 8 = 40` so the row
/// lines up with the pill's leading edge (the attach button floats to the bar's
/// left). Visibility of BgTask / Todo / ModelEffort toggles via arranged-subview
/// `isHidden` — the row's band height is fixed 22pt, so a show/hide never
/// changes the bar band's reported height (§4.2-10). The row is the AppKit
/// analogue of the SwiftUI `HStack(spacing: 8) { … Spacer(minLength: 0) … }`.
///
/// Created ONCE by `InputBarController` (never recreated per session); the
/// owning controller drives `rebind(sessionId:textView:)` from its own
/// `rebind`. The row is NOT a `MainSelectionModel` structural observer (§4.2-9)
/// — `ChatSessionViewController.present(sessionId:)` → `InputBarController.rebind`
/// → `ChromeRowView.rebind` is the only driver.
@MainActor
final class ChromeRowView: NSView {

    // MARK: - Constants (verbatim from InputBarSessionChrome.swift)

    /// Fixed row height (`BarChromeButton` 22pt; the row band never changes).
    static let rowHeight: CGFloat = ChromeButton.height
    /// Horizontal spacing between pills (`InputBarSessionChrome.swift:32`).
    static let spacing: CGFloat = 8
    /// Leading inset aligning the row with the pill (`InputBarSessionChrome.swift:29`).
    static let leadingInset: CGFloat = AttachButtonView.size + 8

    // MARK: - Pickers (owned)

    let permissionPicker: PermissionModePickerController
    let modelEffortPicker: ModelEffortPickerController
    let contextRingPicker: ContextRingPickerController
    let backgroundTaskPicker: BackgroundTaskPickerController
    let todoPicker: TodoPickerController

    private let stackView = NSStackView()

    /// All pickers, in arranged order, for iteration in rebind/teardown.
    private var allPickers: [ChromePickerController] {
        [permissionPicker, backgroundTaskPicker, todoPicker, modelEffortPicker, contextRingPicker]
    }

    // MARK: - Injection seam (tests pass fresh in-memory stores)

    /// Pickers default to `nil` and are constructed in the body (a `@MainActor`
    /// context — the picker inits are main-actor-isolated, so they can't be
    /// `@MainActor` default-argument expressions evaluated in the caller's
    /// isolation). Tests pass pre-built pickers with injected stores.
    init(
        permissionPicker: PermissionModePickerController? = nil,
        modelEffortPicker: ModelEffortPickerController? = nil,
        contextRingPicker: ContextRingPickerController? = nil,
        backgroundTaskPicker: BackgroundTaskPickerController? = nil,
        todoPicker: TodoPickerController? = nil
    ) {
        self.permissionPicker = permissionPicker ?? PermissionModePickerController()
        self.modelEffortPicker = modelEffortPicker ?? ModelEffortPickerController()
        self.contextRingPicker = contextRingPicker ?? ContextRingPickerController()
        self.backgroundTaskPicker = backgroundTaskPicker ?? BackgroundTaskPickerController()
        self.todoPicker = todoPicker ?? TodoPickerController()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = Self.spacing
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // Leading group.
        stackView.addArrangedSubview(self.permissionPicker.button)
        stackView.addArrangedSubview(self.backgroundTaskPicker.button)
        stackView.addArrangedSubview(self.todoPicker.button)
        // Flexible spacer (hugging .defaultLow → expands to push the trailing
        // group right; matches SwiftUI `Spacer(minLength: 0)`).
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(spacer)
        // Trailing group.
        stackView.addArrangedSubview(self.modelEffortPicker.button)
        stackView.addArrangedSubview(self.contextRingPicker.button)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Fixed 22pt band — the row never pumps the bar host height (§4.2-10).
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    // MARK: - Sizing (regime B — fixed height, free width)

    /// Publish the fixed 22pt height and no intrinsic width — the row fills the
    /// width its container gives it; the height is invariant (§4.2-10, R1).
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.rowHeight)
    }

    // MARK: - Rebind (plan §4.2-9)

    /// Rebind every picker to `session`, in place. Each picker cancels its open
    /// popover + per-open observation/timers at the TOP of its own `rebind`
    /// before reading the new session (§4.2-9). `textView` is passed for the
    /// IME `discardMarkedText` before any popover show (§4.2-1).
    func rebind(session: Session, textView: NSTextView?) {
        for picker in allPickers {
            picker.rebind(session: session, textView: textView)
        }
        // Show/hide changed arranged-subview visibility; the row height is fixed
        // so the bar band never moves. Settle layout.
        needsLayout = true
    }

    /// Teardown hook (from `InputBarController.prepareForRemoval`). Closes every
    /// popover + invalidates timers + the bg-task detail sheet.
    func teardown() {
        for picker in allPickers {
            picker.teardown()
        }
    }
}
