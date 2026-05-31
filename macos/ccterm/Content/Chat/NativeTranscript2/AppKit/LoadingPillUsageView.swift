import AppKit

/// The live turn-token-usage counter drawn beside the running dots
/// (`↑in ↓out`). A dedicated subview rather than cell-bitmap text so the
/// numbers can **count up** — odometer / 翻牌器 style — toward each new target
/// instead of snapping.
///
/// Why a roll is needed at all: the displayed output is a client-side estimate
/// that climbs as text streams (and as the CLI's thinking estimate accrues in
/// coarse `+50` cumulative jumps), then takes one larger step when the
/// authoritative `message_delta` total overtakes it. Feeding the *target* into a
/// `StreamPacer` (the same adaptive pacer the typewriter reveal uses) turns
/// those jumps into a continuous `1,2,3,…` climb at the estimated arrival rate —
/// not a decelerating ease-into-each-target, and never a `+50` snap. The runtime
/// drives targets through `Transcript2Coordinator.setTurnUsage` → a single-row
/// `reloadData`, which re-runs the subview plan and calls `apply(spec:)` here;
/// the cell reconciler reuses this view across reloads, so the pacer state
/// survives every tick.
final class LoadingPillUsageView: NSView {

    /// Generic stream pacers that turn the bursty `(input, output)` targets into
    /// a smooth, continuously-counting display. Tokens, not characters, so the
    /// `.counter` tuning (slow readable climb between coarse jumps).
    private var inputPacer = StreamPacer(params: .counter)
    private var outputPacer = StreamPacer(params: .counter)
    /// First `apply` snaps (no roll) so a freshly-created view — first
    /// appearance, or a pill re-pin that recycles a different cell mid-turn —
    /// shows the real total immediately instead of wrongly counting up from 0.
    /// Every subsequent `apply` counts.
    private var hasValue = false

    private var font: NSFont = .systemFont(ofSize: 11)
    private var color: NSColor = .tertiaryLabelColor

    private var tweenTimer: Timer?

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
    /// apply immediately; the numbers count up toward the new values.
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
        inputPacer.setTarget(Double(spec.inputTokens))
        outputPacer.setTarget(Double(spec.outputTokens))

        if !hasValue {
            // Snap on first sight — no count-up from 0.
            hasValue = true
            inputPacer.snap()
            outputPacer.snap()
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
        inputPacer.hasBacklog || outputPacer.hasBacklog
    }

    private func startTweenIfNeeded() {
        guard tweenTimer == nil else { return }
        // `.common` mode so the count-up keeps animating while the transcript is
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
        inputPacer.advance(dt: 1.0 / 60.0)
        outputPacer.advance(dt: 1.0 / 60.0)
        if !needsTween {
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
            "↑\(TurnTokenUsage.abbreviate(inputPacer.displayed)) "
            + "↓\(TurnTokenUsage.abbreviate(outputPacer.displayed))"
        let attr = NSAttributedString(
            string: label,
            attributes: [.font: font, .foregroundColor: color])
        attr.draw(at: .zero)
    }
}
