import AppKit

/// Base class for the five chrome-row pickers (permission / model+effort /
/// context ring / background tasks / todos) — migration plan §4.2. Each picker
/// owns a `ChromeButton` trigger + one `.transient` `NSPopover`, and wires the
/// firstResponder capture/restore + IME-discard discipline (§4.2-1, R13) that
/// every picker needs identically.
///
/// Lifecycle / ownership:
/// - The trigger button is owned here (`button`); `ChromeRowView` adds it as an
///   arranged subview.
/// - `rebind(session:textView:)` cancels any open popover + the picker's
///   per-open observation/timers at the TOP (plan §4.2-9), then re-resolves the
///   bound session and re-arms the always-on trigger observation. Subclasses
///   override `boundSessionChanged()` to refresh their trigger + re-arm.
/// - The popover content VC is built lazily by the subclass via
///   `makePopoverContentViewController()`.
///
/// firstResponder + IME (§4.2-1, R13): before `show`, capture
/// `window.firstResponder`; if the bound input text view `hasMarkedText()`,
/// `discardMarkedText()` so a mid-IME composition click is deterministic; on
/// `popoverDidClose` restore the saved responder (guarded on the window still
/// holding it / still being attached — R13).
@MainActor
class ChromePickerController: NSObject, NSPopoverDelegate {

    // MARK: - Trigger + popover

    /// The chrome-row trigger pill. Owned here; the row arranges it. Built once
    /// via `makeTriggerButton()` so a subclass (ContextRing) can opt out of the
    /// pill surface (a bare ring, no glass / hover / padding).
    let button: ChromeButton

    // MARK: - Init

    override init() {
        self.button = ChromeButton()
        super.init()
        button.actionHandler = { [weak self] in self?.toggle() }
    }

    /// Designated init letting a subclass supply a surface-less trigger (the
    /// ContextRing bare ring, §4.2). Default callers use the no-arg init above.
    init(button: ChromeButton) {
        self.button = button
        super.init()
        button.actionHandler = { [weak self] in self?.toggle() }
    }

    /// The `.transient` popover. Lazily built (once) on first show; content is
    /// rebuilt per-show via `makePopoverContentViewController()`.
    private var popover: NSPopover?

    /// Whether the popover is currently shown (drives the toggle-to-close).
    private(set) var isPopoverShown = false

    // MARK: - Bound session

    /// The session the picker reads + writes through. Re-resolved on rebind.
    private(set) weak var boundSession: Session?

    /// The input text view, used for the IME `discardMarkedText` before show
    /// (§4.2-1). Weak — it may be torn down on a racing rebind (R13).
    private weak var inputTextView: NSTextView?

    /// The firstResponder captured before the popover stole key-window, restored
    /// on `popoverDidClose`. Weak so a racing teardown of the saved responder
    /// doesn't keep it alive; the restore re-checks it is still in the window.
    private weak var savedFirstResponder: NSResponder?

    /// The session identity captured alongside `savedFirstResponder`. The
    /// restore only fires if the bound session is unchanged since capture — an
    /// async `popoverDidClose` that lands AFTER a rebind to a new session must
    /// NOT clobber the freshly-bound bar's responder (R13 / timing review).
    private weak var savedResponderSession: Session?

    nonisolated deinit {}

    // MARK: - Rebind (plan §4.2-9)

    /// Reset the picker to a new session, in place. Cancels any open popover +
    /// per-open observation/timers at the TOP, then re-resolves the session and
    /// re-arms the always-on trigger observation (subclass `boundSessionChanged`).
    func rebind(session: Session, textView: NSTextView?) {
        // (1) cancel any open popover + per-open scopes at the top. Use the
        //     rebind-specific close that clears the saved responder synchronously
        //     so a late popoverDidClose can't refocus a torn-down/stale responder
        //     (R13 / timing review).
        closePopoverForRebind()
        cancelTriggerObservation()

        // (2) re-resolve the bound session + input text view.
        boundSession = session
        inputTextView = textView

        // (3) subclass refreshes trigger + re-arms the always-on observation.
        boundSessionChanged()
    }

    /// Teardown hook (called from `ChromeRowView.teardown` → InputBarController
    /// prepareForRemoval). Closes the popover + cancels observation.
    func teardown() {
        closePopoverForRebind()
        cancelTriggerObservation()
        boundSession = nil
        inputTextView = nil
    }

    // MARK: - Subclass hooks

    /// Build the popover content VC for the current bound session. Called on
    /// every show (no cell reuse → fresh content tree, §4.2-4).
    func makePopoverContentViewController() -> NSViewController {
        fatalError("subclass must override makePopoverContentViewController()")
    }

    /// Re-resolve the trigger label / visibility and (re)arm the always-on
    /// observation. Subclasses override; the base default refreshes nothing.
    func boundSessionChanged() {}

    /// Cancel the always-on trigger observation. Subclasses override to flip
    /// their `*ObservationActive` flag false so a stale re-arm closure no-ops.
    func cancelTriggerObservation() {}

    /// Fired from `popoverWillShow` so subclasses can arm a per-open
    /// observation scope / start a timer (context-usage request, bg-task timer).
    func popoverWillBecomeShown() {}

    /// Fired from `popoverDidClose` so subclasses can tear down their per-open
    /// scope / invalidate timers.
    func popoverDidBecomeHidden() {}

    // MARK: - Show / toggle / close

    /// Toggle the popover (a second click on an open trigger closes it,
    /// mirroring SwiftUI `isPresented.toggle()`).
    func toggle() {
        if isPopoverShown {
            closePopoverIfShown()
        } else {
            show()
        }
    }

    /// Show the popover below the trigger (`preferredEdge: .maxY` — the AppKit
    /// analogue of SwiftUI `arrowEdge: .top`, which places the popover BELOW the
    /// trigger with the arrow on its top edge, §4.2 popover-edge parity).
    func show() {
        guard !isPopoverShown, button.window != nil else { return }

        // (a) capture the firstResponder + deterministically end any IME
        //     composition before the popover steals key-window (§4.2-1, R13).
        savedFirstResponder = button.window?.firstResponder
        savedResponderSession = boundSession
        if let tv = inputTextView, tv.hasMarkedText() {
            tv.inputContext?.discardMarkedText()
        }

        let pop = popover ?? makePopover()
        popover = pop
        pop.contentViewController = makePopoverContentViewController()
        isPopoverShown = true
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func makePopover() -> NSPopover {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self
        return pop
    }

    private func closePopoverIfShown() {
        guard isPopoverShown, let popover else {
            isPopoverShown = false
            return
        }
        popover.performClose(nil)
        // performClose triggers popoverDidClose synchronously in most cases, but
        // guard the flag here too in case the delegate doesn't fire (rebind path).
        isPopoverShown = false
    }

    /// Close the popover on a REBIND/teardown path WITHOUT restoring focus. A
    /// `.transient` popover's `popoverDidClose` lands async (beforeWaiting) — one
    /// tick after the synchronous rebind that re-binds `boundSession` /
    /// `inputTextView` to a NEW session. Clearing `savedFirstResponder`
    /// synchronously here makes that late delegate callback a no-op, so it can't
    /// clobber the freshly-bound bar's responder (R13 / timing review).
    private func closePopoverForRebind() {
        savedFirstResponder = nil
        savedResponderSession = nil
        closePopoverIfShown()
    }

    /// The captured main window before the popover stole key-window. Captured
    /// before `performClose` so a window-level sheet (bg-task detail) can be
    /// scheduled on it after the transient close settles (§4.2-5).
    var anchorWindow: NSWindow? { button.window }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        popoverWillBecomeShown()
    }

    func popoverDidClose(_ notification: Notification) {
        isPopoverShown = false
        popoverDidBecomeHidden()
        // Restore the saved firstResponder, guarded on: (a) the bound session
        // being UNCHANGED since capture — a rebind clears `savedFirstResponder`
        // synchronously, but also re-check identity in case this fires for a
        // genuine user close after a rebind armed a fresh capture; (b) the window
        // still being attached and the responder still living in it (R13 — a
        // racing rebind may have torn the saved responder down).
        defer {
            savedFirstResponder = nil
            savedResponderSession = nil
        }
        guard savedResponderSession == nil || savedResponderSession === boundSession else { return }
        if let window = button.window, let saved = savedFirstResponder {
            if window.firstResponder !== saved {
                window.makeFirstResponder(saved)
            }
        }
    }

    // MARK: - Test-observation points (read-only; no production consumers)

    /// Whether the firstResponder was captured and is pending restore. Read by
    /// tests to drive the show→close restore cycle.
    var capturedFirstResponderForTest: NSResponder? { savedFirstResponder }
}
