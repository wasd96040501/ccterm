import AppKit

/// The draft-landing surface root, pure AppKit (migration plan §4.6). Replaces
/// the SwiftUI `DraftSessionLandingView` (`ZStack { DotGridBackground();
/// VStack { hero; subtitle; branchPill; inputBar } }`): a `DotGridView` backdrop
/// pinned 4-edge with a centered hero column on top — sparkles + "Start Building
/// <project>", the abbreviated path, an optional read-only branch pill, and the
/// embedded input bar (the `InputBarController`'s pill + chrome row).
///
/// ## Per-bind re-render, not rebuild (plan §4.6-7, R-draft-rebuild)
///
/// The hero text / subtitle / branch pill differ per draft, but the embedded
/// bar must NOT be rebuilt on a draft → draft switch (the bar is created once by
/// the VC and rebound in place). `update(session:)` re-renders ONLY the hero
/// labels + pill; the bar is left untouched (the VC calls `rebind` separately).
///
/// ## Regime-A no-collapse (plan R1)
///
/// This view IS the `DraftSessionLandingViewController`'s fill-the-pane content,
/// pinned 4-edge. It overrides `intrinsicContentSize = .zero`; the hero column
/// is centered + width-capped at `composeMaxWidth` with no `@required` minimum,
/// so its content size never leaks up into the VC's `fittingSize.height` (keeps
/// `AppKitSwiftUIBoundaryTests.testComposeAndDraftLandingFillPanesDoNotCollapse`
/// green).
@MainActor
final class DraftLandingContentView: NSView {
    nonisolated deinit {}

    private let grid = DotGridView()

    // Hero column pieces.
    private let titleIcon = BaselineNudgedImageView()
    private let titleStaticLabel = NSTextField(labelWithString: String(localized: "Start Building"))
    private let titleProjectLabel = NSTextField(labelWithString: "")
    private let titleRow = NSStackView()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let branchPill = DraftBranchPillView()
    private let column = NSStackView()

    /// The bar/chrome assembly. Reuses `RestingBarContainerView` so the
    /// `composeMaxWidth` cap + `barSpacing` constants stay single-sourced with
    /// the chat resting bar; `bottomInset: 0` because the hero column owns the
    /// vertical rhythm (the SwiftUI `inputBar.padding(.top, 6)` slot).
    private let barHost: RestingBarContainerView

    init(barView: InputBarView, chromeRow: NSView) {
        barHost = RestingBarContainerView(
            barView: barView,
            chromeRow: chromeRow,
            innerMaxWidth: ChatSessionViewController.composeMaxWidth,
            horizontalInset: 0,
            bottomInset: 0,
            barSpacing: RestingBarContainerView.barSpacing)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        buildHero()
        addSubview(column)

        // `.title.weight(.semibold)` ≈ title1 point size, semibold.
        let titleFont = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .title1).pointSize, weight: .semibold)
        titleStaticLabel.font = titleFont
        titleStaticLabel.textColor = .labelColor
        titleProjectLabel.font = titleFont
        titleProjectLabel.textColor = .controlAccentColor
        titleProjectLabel.lineBreakMode = .byTruncatingTail
        titleProjectLabel.cell?.usesSingleLineMode = true
        titleProjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.cell?.usesSingleLineMode = true

        // The hero column wants `composeMaxWidth` but the pull is placed JUST
        // BELOW `fittingSizeCompression` (50) so `fittingSize` collapses it (plan
        // R1) — honored in the live solve, yielded to in `fittingSize`.
        let idealPriority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1)
        let capWidth = column.widthAnchor.constraint(
            equalToConstant: ChatSessionViewController.composeMaxWidth)
        capWidth.priority = idealPriority

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Pinned by centerX/centerY ONLY (no edge pin to the root) so the
            // hero's content height never forces the root taller in `fittingSize`
            // — the regime-A no-collapse contract (plan R1). The `<=` caps are
            // required inequalities (shrink the column on a narrow pane, never
            // pull the root); the `== composeMaxWidth` pull sits below the
            // fitting-size compression priority.
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.widthAnchor.constraint(
                lessThanOrEqualToConstant: ChatSessionViewController.composeMaxWidth),
            column.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor,
                constant: -2 * ChatSessionViewController.detailHorizontalInset),
            capWidth,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Regime-A: publish `.zero` so the hero column's content size never leaks
    /// up into the VC's 4-edge-pinned `fittingSize.height` (plan R1).
    override var intrinsicContentSize: NSSize { .zero }

    private func buildHero() {
        // Hero row: sparkles + "Start Building" + project name.
        titleIcon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        titleIcon.contentTintColor = .controlAccentColor
        titleIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        titleIcon.translatesAutoresizingMaskIntoConstraints = false

        titleStaticLabel.translatesAutoresizingMaskIntoConstraints = false
        titleProjectLabel.translatesAutoresizingMaskIntoConstraints = false
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addArrangedSubview(titleIcon)
        titleRow.addArrangedSubview(titleStaticLabel)
        titleRow.addArrangedSubview(titleProjectLabel)

        // SwiftUI nudged the sparkles glyph +2pt down off the title baseline
        // (`.alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] + 2 }`)
        // so the symbol optically centers against the title cap-height. The
        // `titleRow` stack baseline-aligns its arranged views; `titleIcon` is a
        // `BaselineNudgedImageView` that reports a first baseline 2pt larger, so
        // the stack places it 2pt lower with NO extra (conflicting) constraint —
        // the idiomatic AppKit equivalent of the alignment guide.

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        branchPill.translatesAutoresizingMaskIntoConstraints = false

        // Centered hero column, `VStack(spacing: 14)`. The bar's 6pt top
        // padding (→ 20pt gap) is re-homed onto the last visible sibling by
        // `homeBarTopSpacing()`.
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(titleRow)
        column.addArrangedSubview(subtitleLabel)
        column.addArrangedSubview(branchPill)
        column.addArrangedSubview(barHost)
        // SwiftUI bar had `.padding(.top, 6)` ON THE BAR ITSELF, on top of the
        // `VStack(spacing: 14)` → a 20pt gap above the bar regardless of which
        // siblings are present. `homeBarTopSpacing()` (re-run on every
        // `update`) re-homes the 20pt custom spacing onto whichever view is the
        // last VISIBLE one above the bar, so the gap survives the cwd==nil
        // (subtitle+pill hidden) and no-branch edges. Seed it for the build-time
        // state (project shown, subtitle + pill present until first `update`).
        homeBarTopSpacing()
        // The bar fills the column width (the pill self-caps at composeMaxWidth
        // inside RestingBarContainerView, but with innerMaxWidth == column cap
        // it fills the column).
        barHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    /// Re-home the 20pt bar-top gap onto the last VISIBLE arranged view above
    /// the bar, clearing the custom spacing on the others back to the stack
    /// default (14). NSStackView ignores custom spacing anchored to a hidden
    /// arranged view, so without this re-home the bar's gap would silently fall
    /// back to 14 in the no-branch / cwd==nil edges (reviewer-flagged: the
    /// SwiftUI `.padding(.top, 6)` was on the bar and so was sibling-independent).
    private func homeBarTopSpacing() {
        // Reset all three candidates to the stack default first.
        column.setCustomSpacing(NSStackView.useDefaultSpacing, after: titleRow)
        column.setCustomSpacing(NSStackView.useDefaultSpacing, after: subtitleLabel)
        column.setCustomSpacing(NSStackView.useDefaultSpacing, after: branchPill)
        // Then put the 20pt on the last visible view preceding the bar.
        let last: NSView
        if !branchPill.isHidden {
            last = branchPill
        } else if !subtitleLabel.isHidden {
            last = subtitleLabel
        } else {
            last = titleRow
        }
        column.setCustomSpacing(20, after: last)
    }

    /// Re-render the hero labels + branch pill from the current draft state.
    /// Does NOT touch the embedded bar (the VC rebinds it in place).
    func update(session: Session) {
        let folderName = session.cwd.map { ($0 as NSString).lastPathComponent }
        if let name = folderName, !name.isEmpty {
            titleProjectLabel.stringValue = name
            titleProjectLabel.isHidden = false
        } else {
            titleProjectLabel.stringValue = ""
            titleProjectLabel.isHidden = true
        }

        if let cwd = session.cwd {
            subtitleLabel.stringValue = Self.abbreviatedPath(cwd)
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.stringValue = ""
            subtitleLabel.isHidden = true
        }

        if let branch = session.sourceBranch ?? session.worktreeBranch {
            branchPill.configure(branch: branch, isWorktree: session.isWorktree)
            branchPill.isHidden = false
        } else {
            branchPill.isHidden = true
        }

        // Re-home the 20pt bar-top gap onto the last visible view above the bar
        // (handles the no-branch and cwd==nil edges where the prior anchor view
        // is now hidden and NSStackView would ignore its custom spacing).
        homeBarTopSpacing()
    }

    /// `~`-abbreviate a home-relative path (verbatim from the SwiftUI body).
    static func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Baseline-nudged sparkles icon

/// An `NSImageView` that reports its first baseline 2pt LOWER within its own
/// bounds. In a `.firstBaseline`-aligned `NSStackView` the stack raises the
/// view to put that (lower) baseline on the common line, so the glyph sits ~2pt
/// UP relative to the title text — the AppKit equivalent of the SwiftUI
/// `.alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] + 2 }`
/// the draft-landing hero used to optically center the sparkles against the
/// title cap-height (`#142`). Done via the baseline-offset override rather than
/// an explicit constraint so it cannot conflict with the stack's required
/// baseline-alignment constraint on the same view.
@MainActor
final class BaselineNudgedImageView: NSImageView {
    nonisolated deinit {}

    override var firstBaselineOffsetFromTop: CGFloat {
        super.firstBaselineOffsetFromTop + 2
    }
}

// MARK: - Read-only branch pill

/// The draft-landing read-only branch chip (`DraftSessionLandingView.branchPill`):
/// an SF symbol (swaps on `isWorktree`) + a 12pt label inside a 0.5pt
/// `separatorColor`@0.7 capsule, 10pt horizontal / 4pt vertical inset. Decorative
/// (no picker) — the draft's branch is fixed when `/new` / `/clear` copies it.
@MainActor
final class DraftBranchPillView: NSView {
    nonisolated deinit {}

    private static let hInset: CGFloat = 10
    private static let vInset: CGFloat = 4

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleNone
        addSubview(imageView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        addSubview(label)

        NSLayoutConstraint.activate([
            // 14×14 icon frame (matches the SwiftUI `.frame(width: 14, height: 14)`).
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hInset),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 4pt icon→label spacing (`HStack(spacing: 4)`).
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hInset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.vInset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.vInset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Decorative pill — never absorb clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The capsule stroke resolves `separatorColor` in `draw(_:)`, which a
    /// layer-backed view does not auto-re-invoke on a dark/light flip (R14).
    /// Mark dirty so the stroke re-resolves on the next display, matching the
    /// SwiftUI `Capsule().strokeBorder(Color(nsColor:.separatorColor)…)` that
    /// re-resolved automatically.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(branch: String, isWorktree: Bool) {
        imageView.image = NSImage(
            systemSymbolName: isWorktree ? "folder.badge.plus" : "arrow.triangle.branch",
            accessibilityDescription: nil)
        label.stringValue = branch
    }

    override func draw(_ dirtyRect: NSRect) {
        // Static 0.5pt separatorColor@0.7 capsule stroke (inset so it stays
        // fully inside bounds), matching the SwiftUI `Capsule().strokeBorder(...)`.
        let radius = bounds.height / 2
        let strokeRect = bounds.insetBy(dx: 0.25, dy: 0.25)
        let strokePath = NSBezierPath(
            roundedRect: strokeRect, xRadius: radius - 0.25, yRadius: radius - 0.25)
        strokePath.lineWidth = 0.5
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        strokePath.stroke()
    }
}
