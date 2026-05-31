import AppKit

/// The live trailing chip drawn beside the running dots. Two pieces:
///
/// 1. An **elapsed turn clock** (`5s`, `1m 3s`, `1d 2h 4m 9s` — non-zero units
///    only, seconds always when everything is zero) that counts up on its own
///    from `startedAt`. A self-owned 1 Hz timer redraws it; no row reload is
///    needed per second.
/// 2. Once the turn has produced tokens, a ` · ↑in ↓out` suffix whose numbers
///    **count up** — odometer / 翻牌器 style — toward each new target instead of
///    snapping. A `·` separates the clock from the counter; with no tokens yet
///    the separator and counter are omitted.
///
/// Why a token roll is needed at all: the displayed output is a client-side
/// estimate that climbs as text streams (and as the CLI's thinking estimate
/// accrues in coarse `+50` cumulative jumps), then takes one larger step when
/// the authoritative `message_delta` total overtakes it. Feeding the *target*
/// into a `StreamPacer` (the same adaptive pacer the typewriter reveal uses)
/// turns those jumps into a continuous `1,2,3,…` climb at the estimated arrival
/// rate. The runtime drives targets through `Transcript2Coordinator.setTurnUsage`
/// (and the clock anchor through `setTurnStartedAt`) → a single-row `reloadData`,
/// which re-runs the subview plan and calls `apply(spec:)` here; the cell
/// reconciler reuses this view across reloads, so pacer + clock state survive.
///
/// The view **owns its own width**: the clock string grows as it ticks, so on
/// every `apply` / tick it re-measures its content and resizes its frame to fit.
/// The cell reconciler positions it (the layout reserves a best-effort first
/// frame); the live width is this view's responsibility.
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

    /// Whether the ` · ↑in ↓out` token suffix should be drawn at all. False
    /// before any tokens accrue, so the separator and counter stay hidden while
    /// only the clock is showing.
    private var hasTokens = false

    /// Turn start instant the elapsed clock counts up from, or `nil` for no
    /// clock. Driven by the spec; the 1 Hz timer below reads it live.
    private var startedAt: Date?

    private var font: NSFont = .systemFont(ofSize: 11)
    private var color: NSColor = .tertiaryLabelColor

    /// 60 fps timer driving the token odometer roll (runs only while a pacer has
    /// a backlog). Distinct from `clockTimer`, which ticks the elapsed display.
    private var tweenTimer: Timer?
    /// 1 Hz timer advancing the elapsed clock (runs while `startedAt != nil`).
    private var clockTimer: Timer?

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Point the chip at a new spec. Typography + clock anchor apply
    /// immediately; the token numbers count up toward the new values, and the
    /// clock (re)starts its self-tick.
    func apply(_ spec: SubviewPlan.UsageCounter) {
        if font != spec.font { font = spec.font }
        if color != spec.color { color = spec.color }
        startedAt = spec.startedAt
        hasTokens = spec.inputTokens > 0 || spec.outputTokens > 0

        inputPacer.setTarget(Double(spec.inputTokens))
        outputPacer.setTarget(Double(spec.outputTokens))

        if !hasValue {
            // Snap on first sight — no count-up from 0.
            hasValue = true
            inputPacer.snap()
            outputPacer.snap()
            tweenTimer?.invalidate()
            tweenTimer = nil
        } else if needsTween {
            startTweenIfNeeded()
        }

        // Run the elapsed clock while the turn is in flight; stop it otherwise.
        if startedAt != nil {
            startClockIfNeeded()
        } else {
            clockTimer?.invalidate()
            clockTimer = nil
        }

        resizeToFitContent()
        needsDisplay = true
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
        resizeToFitContent()
        needsDisplay = true
    }

    private func startClockIfNeeded() {
        guard clockTimer == nil else { return }
        // `.common` so the clock keeps ticking while the transcript is scrolled.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else {
                t.invalidate()
                return
            }
            // Cheap: re-measure (the clock string may have grown a unit) and
            // repaint. The token suffix, if any, repaints with its current value.
            self.resizeToFitContent()
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    /// Resize the frame width to fit the current composed label, so the growing
    /// clock string never clips. Position + height stay as the reconciler set
    /// them; only width is self-owned.
    private func resizeToFitContent() {
        let target = ceil(composedAttributed().size().width) + 2
        if abs(frame.size.width - target) > 0.5 {
            setFrameSize(NSSize(width: target, height: frame.size.height))
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    /// Stop the timers when the view leaves the hierarchy (pill removed / cell
    /// recycled) so stray block-timers don't keep firing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tweenTimer?.invalidate()
            tweenTimer = nil
            clockTimer?.invalidate()
            clockTimer = nil
        }
    }

    deinit {
        tweenTimer?.invalidate()
        clockTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        composedAttributed().draw(at: .zero)
    }

    /// The full chip string for the current instant: elapsed clock, then a
    /// ` · ↑in ↓out` suffix once tokens exist.
    private func composedLabel() -> String {
        var label = ""
        if let startedAt {
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
            label = Self.formatElapsed(elapsed)
        }
        if hasTokens {
            let token =
                "↑\(TurnTokenUsage.abbreviate(inputPacer.displayed)) "
                + "↓\(TurnTokenUsage.abbreviate(outputPacer.displayed))"
            label += label.isEmpty ? token : " · \(token)"
        }
        return label
    }

    private func composedAttributed() -> NSAttributedString {
        NSAttributedString(
            string: composedLabel(),
            attributes: [.font: font, .foregroundColor: color])
    }

    /// `45 → "45s"`, `63 → "1m 3s"`, `3661 → "1h 1m 1s"`, `90183 → "1d 1h 3s"`.
    /// Non-zero units only (a zero higher unit is dropped — `1d 0h 2m 3s` reads
    /// `1d 2m 3s`); seconds always show when everything else is zero.
    static func formatElapsed(_ seconds: Int) -> String {
        let s = seconds % 60
        let m = (seconds / 60) % 60
        let h = (seconds / 3600) % 24
        let d = seconds / 86400
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 || parts.isEmpty { parts.append("\(s)s") }
        return parts.joined(separator: " ")
    }
}
