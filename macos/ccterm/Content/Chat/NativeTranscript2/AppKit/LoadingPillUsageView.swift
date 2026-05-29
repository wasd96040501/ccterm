import AppKit

/// The live turn-token-usage counter drawn beside the running dots
/// (`↑in ↓out`). A dedicated subview rather than cell-bitmap text so the
/// numbers can **roll up** — odometer / 翻牌器 style — toward each new target
/// instead of snapping.
///
/// Why a roll is needed at all: the CLI reports authoritative `output_tokens`
/// only once per message (the trailing `message_delta`), so the displayed
/// total tends to climb in a smooth stream of estimate updates and then take
/// one larger step when the real figure lands. Easing the *displayed* value
/// toward the target turns both into a continuous count-up. The runtime drives
/// targets through `Transcript2Coordinator.setTurnUsage` → a single-row
/// `reloadData`, which re-runs the subview plan and calls `apply(spec:)` here;
/// the cell reconciler reuses this view across reloads, so the roll state
/// survives every tick.
final class LoadingPillUsageView: NSView {

    private var targetInput: Int = 0
    private var targetOutput: Int = 0
    /// Currently-displayed (fractional) values; eased toward the targets.
    private var shownInput: Double = 0
    private var shownOutput: Double = 0
    /// First `apply` snaps (no roll) so a freshly-created view — first
    /// appearance, or a pill re-pin that recycles a different cell mid-turn —
    /// shows the real total immediately instead of wrongly rolling up from 0.
    /// Every subsequent `apply` rolls.
    private var hasValue = false

    private var font: NSFont = .systemFont(ofSize: 11)
    private var color: NSColor = .tertiaryLabelColor

    private var tweenTimer: Timer?

    /// Per-frame easing toward the target. ~0.22 converges a step in ~0.25s at
    /// 60fps — fast enough to feel responsive, slow enough to read as a roll.
    private static let easing: Double = 0.22
    /// Snap threshold: once within this many tokens, jump to the target and
    /// stop the timer (avoids an asymptotic crawl that never settles).
    private static let snapEpsilon: Double = 0.5

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Point the counter at a new `(input, output)` target. Typography updates
    /// apply immediately; the numbers ease toward the new values.
    func apply(_ spec: SubviewPlan.UsageCounter) {
        var styleChanged = false
        if font != spec.font {
            font = spec.font
            styleChanged = true
        }
        if color != spec.color {
            color = spec.color
            styleChanged = true
        }
        targetInput = spec.inputTokens
        targetOutput = spec.outputTokens

        if !hasValue {
            // Snap on first sight — no roll from 0.
            hasValue = true
            shownInput = Double(targetInput)
            shownOutput = Double(targetOutput)
            tweenTimer?.invalidate()
            tweenTimer = nil
            needsDisplay = true
            return
        }

        if needsTween {
            startTweenIfNeeded()
        } else if styleChanged {
            needsDisplay = true
        }
    }

    private var needsTween: Bool {
        abs(Double(targetInput) - shownInput) > Self.snapEpsilon
            || abs(Double(targetOutput) - shownOutput) > Self.snapEpsilon
    }

    private func startTweenIfNeeded() {
        guard tweenTimer == nil else { return }
        // `.common` mode so the roll keeps animating while the transcript is
        // being scrolled / tracked.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else {
                t.invalidate()
                return
            }
            self.stepTween(t)
        }
        RunLoop.main.add(timer, forMode: .common)
        tweenTimer = timer
    }

    private func stepTween(_ timer: Timer) {
        shownInput += (Double(targetInput) - shownInput) * Self.easing
        shownOutput += (Double(targetOutput) - shownOutput) * Self.easing
        if !needsTween {
            shownInput = Double(targetInput)
            shownOutput = Double(targetOutput)
            timer.invalidate()
            if tweenTimer === timer { tweenTimer = nil }
        }
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    /// Stop the timer when the view leaves the hierarchy (pill removed / cell
    /// recycled) so a stray block-timer doesn't keep firing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tweenTimer?.invalidate()
            tweenTimer = nil
        }
    }

    deinit {
        tweenTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        let label =
            "↑\(TurnTokenUsage.abbreviate(Int(shownInput.rounded()))) "
            + "↓\(TurnTokenUsage.abbreviate(Int(shownOutput.rounded())))"
        let attr = NSAttributedString(
            string: label,
            attributes: [.font: font, .foregroundColor: color])
        attr.draw(at: .zero)
    }
}
