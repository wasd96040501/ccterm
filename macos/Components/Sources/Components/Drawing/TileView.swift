import AppKit
import DisplayModels

/// A kind of work as a 16-pt tile: a Lamé squircle |x|⁴ + |y|⁴ = 7.5⁴ — the
/// sidebar glyphs' family — in a quaternary fill, the kind's glyph in
/// secondary ink (design/transcript/README.md "Tile").
///
/// States change the tile, never the row around it: *preparing* dims the
/// glyph; *running* sends a ⅓-length arc round the outline once a second;
/// *background* dashes the outline and turns it every four seconds;
/// *waiting* outlines it in coral; *failed* washes it red under a red `!`;
/// *stopped* swaps the glyph for a stop square. The arc is the only thing
/// that moves, and Reduce Motion turns it into a slow pulse.
///
/// Every row that shows work — a run, an item, news, a caption, a jump bar —
/// draws its tile with this view.
@MainActor
public final class TileView: NSView {
    private static let side: CGFloat = 16

    public var tile = Tile(glyph: .tool(.other), state: .done) {
        didSet {
            guard tile != oldValue else { return }
            update()
        }
    }

    private let fill = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let glyph = NSImageView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        layer?.masksToBounds = false
        let path = Self.squircle
        fill.path = path
        fill.frame = bounds
        ring.path = path
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.lineCap = .round
        ring.frame = bounds
        layer?.addSublayer(fill)
        layer?.addSublayer(ring)
        glyph.imageScaling = .scaleNone
        glyph.frame = bounds
        addSubview(glyph)
        update()
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    // MARK: - State

    private func update() {
        glyph.image = Self.image(for: tile)
        glyph.alphaValue = tile.state == .preparing ? 0.42 : 1
        needsDisplay = true
        animate()
    }

    /// Colours are resolved here, in the view's appearance, so they follow
    /// light and dark.
    private func paint() {
        let state = tile.state
        fill.fillColor = (state == .failed ? NSColor.systemRed.withAlphaComponent(0.16) : .quaternarySystemFill).cgColor
        glyph.contentTintColor =
            switch state {
            case .failed: .systemRed
            case .stopped: .tertiaryLabelColor
            default: .secondaryLabelColor
            }
        switch state {
        case .running: ring.strokeColor = NSColor.secondaryLabelColor.cgColor
        case .background: ring.strokeColor = NSColor.tertiaryLabelColor.cgColor
        case .waiting: ring.strokeColor = NSColor.sidebarCoral.cgColor
        default: ring.strokeColor = nil
        }
    }

    private func animate() {
        ring.removeAllAnimations()
        ring.lineDashPattern = nil
        ring.opacity = 1
        let length = Self.squircleLength
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window == nil
        switch tile.state {
        case .running where NSWorkspace.shared.accessibilityDisplayShouldReduceMotion:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            ring.add(pulse, forKey: "pulse")
        case .running:
            ring.lineDashPattern = [NSNumber(value: length / 3), NSNumber(value: length * 2 / 3)]
            guard !still else { break }
            let travel = CABasicAnimation(keyPath: "lineDashPhase")
            travel.fromValue = 0
            travel.toValue = -length
            travel.duration = 1
            travel.repeatCount = .infinity
            ring.add(travel, forKey: "travel")
        case .background:
            ring.lineDashPattern = [NSNumber(value: length * 0.03), NSNumber(value: length * 0.0325)]
            guard !still else { break }
            let turn = CABasicAnimation(keyPath: "lineDashPhase")
            turn.fromValue = 0
            turn.toValue = -length
            turn.duration = 4
            turn.repeatCount = .infinity
            ring.add(turn, forKey: "turn")
        default:
            break
        }
    }

    // MARK: - Glyphs

    /// The design's glyph for the tile (`GLYPHS` in design/transcript/preview.js,
    /// built by design/transcript-icons): 16 × 16, drawn over the whole tile.
    private static func image(for tile: Tile) -> NSImage {
        switch tile.state {
        case .failed: return .transcriptTileFail
        case .stopped: return .transcriptTileStop
        default: break
        }
        switch tile.glyph {
        case .tool(let kind):
            switch kind {
            case .command: return .transcriptTileCommand
            case .change: return .transcriptTileChange
            case .create: return .transcriptTileCreate
            case .read: return .transcriptTileRead
            case .search: return .transcriptTileSearch
            case .web: return .transcriptTileWeb
            case .agent: return .transcriptTileAgent
            case .tasks: return .transcriptTileTasks
            case .schedule: return .transcriptTileSchedule
            case .advisor: return .transcriptTileAdvisor
            case .skill: return .transcriptTileSkill
            case .worktree: return .transcriptTileWorktree
            case .message: return .transcriptTileMessage
            case .notify: return .transcriptTileNotify
            case .other: return .transcriptTileOther
            }
        case .workflow: return .transcriptTileWorkflow
        case .monitor: return .transcriptTileMonitor
        case .question: return .transcriptTileQuestion
        case .plan: return .transcriptTilePlan
        case .image: return .transcriptTileImage
        }
    }

    // MARK: - Geometry

    /// |x|⁴ + |y|⁴ = 7.5⁴ about the tile's centre, as `design/sidebar-icons`
    /// draws its shapes.
    private static let squircle: CGPath = {
        let path = CGMutablePath()
        for (index, point) in squirclePoints.enumerated() {
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }()

    private static let squirclePoints: [CGPoint] = (0..<96).map { step in
        let t = 2 * Double.pi * Double(step) / 96
        let (c, s) = (cos(t), sin(t))
        let radius = 7.5
        return CGPoint(
            x: 8 + radius * copysign(pow(abs(c), 0.5), c),
            y: 8 + radius * copysign(pow(abs(s), 0.5), s))
    }

    /// The outline's length, which the arc and the dashes are measured in.
    private static let squircleLength: Double = zip(squirclePoints, squirclePoints.dropFirst() + [squirclePoints[0]])
        .reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
}
