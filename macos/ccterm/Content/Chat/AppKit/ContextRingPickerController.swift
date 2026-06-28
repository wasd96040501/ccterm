import AgentSDK
import AppKit
import Observation

/// Token-count formatter shared by the context breakdown + summary (verbatim
/// from `ContextRingButton.swift:359-370`). NOT localized — raw CLI numbers.
enum ContextTokenFormat {
    static func format(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        }
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return String(count)
    }
}

/// AppKit replacement for `ContextRingButton.swift` (migration plan §4.2).
/// Footer-row indicator: a `ProgressRingLayer` trigger (always rendered, even at
/// 0 tokens — §4.2 ContextRing constants) opening a breakdown + summary popover.
/// `requestContextUsage()` fires once per open from the content VC's
/// `viewWillAppear` (§4.2-8), NOT from bind/rebind.
///
/// The trigger is a `ProgressRingLayer` framed 22×22 (size param stays 12, the
/// path centers in bounds) inside a plain clickable host (NOT a `ChromeButton`
/// — the ring is the affordance, no pill surface, matching SwiftUI's bare
/// `Button { ProgressRingView }.buttonStyle(.plain)`).
@MainActor
final class ContextRingPickerController: ChromePickerController {

    private let ring = ProgressRingLayer(percent: 0, size: 12)
    private var triggerObservationActive = false
    /// Held so `viewWillAppear` can fire the once-per-open request against the
    /// live session; rebuilt each show.
    private weak var openContentVC: ContextBreakdownContentViewController?

    override init() {
        // The ContextRing trigger is the bare ring (no pill surface, no hover
        // overlay, no horizontal padding) — matching SwiftUI's
        // `Button { ProgressRingView }.buttonStyle(.plain)`
        // (ContextRingButton.swift:18-23). Build the trigger with
        // `showsSurface: false` so the BarSurfaceView glass + hover fill are
        // never created, and the footprint is exactly the 22pt ring.
        super.init(button: ChromeButton(showsSurface: false))
        ring.translatesAutoresizingMaskIntoConstraints = false
        button.contentStack.addArrangedSubview(ring)
        NSLayoutConstraint.activate([
            ring.widthAnchor.constraint(equalToConstant: 22),
            ring.heightAnchor.constraint(equalToConstant: 22),
        ])
        button.setAccessibilityLabel(String(localized: "Context usage"))
    }

    nonisolated deinit {}

    // MARK: - percent (verbatim from ContextRingButton.percent)

    private var percent: Double {
        guard let session = boundSession else { return 0 }
        let total = Double(session.contextWindowTokens)
        guard total > 0 else { return 0 }
        let used = Double(session.contextUsedTokens)
        return min(max(used / total * 100, 0), 100)
    }

    // MARK: - Rebind + re-arm

    override func boundSessionChanged() {
        guard let session = boundSession else { return }
        refreshTrigger()
        startTriggerObservation(for: session)
    }

    override func cancelTriggerObservation() {
        triggerObservationActive = false
    }

    private func refreshTrigger() {
        ring.percent = percent
        button.setAccessibilityValue("\(Int(percent.rounded()))%")
    }

    private func startTriggerObservation(for session: Session) {
        triggerObservationActive = true
        observeTrigger(session)
    }

    private func observeTrigger(_ session: Session) {
        withObservationTracking {
            _ = session.contextUsedTokens
            _ = session.contextWindowTokens
        } onChange: { [weak self, weak session] in
            DispatchQueue.main.async {
                guard let self, let session,
                    self.triggerObservationActive, self.boundSession === session
                else { return }
                self.refreshTrigger()
                self.observeTrigger(session)
            }
        }
    }

    // MARK: - Popover content

    override func makePopoverContentViewController() -> NSViewController {
        guard let session = boundSession else {
            return PopoverScrollContentViewController(width: ContextBreakdownContentViewController.popoverWidth)
        }
        let vc = ContextBreakdownContentViewController(session: session)
        openContentVC = vc
        return vc
    }

    override func popoverDidBecomeHidden() {
        openContentVC?.stopObserving()
        openContentVC = nil
    }
}
