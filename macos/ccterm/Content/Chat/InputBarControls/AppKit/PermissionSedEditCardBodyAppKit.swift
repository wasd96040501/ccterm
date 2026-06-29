import AgentSDK
import AppKit

/// AppKit body for `.sedEdit` permission requests — the pure-AppKit port of the
/// SwiftUI `PermissionSedEditCardBody` (`PermissionSedEditCardBody.swift`,
/// `InputBarControls/`). Plan §4.4-5: the diff-family bodies port BOTH arms —
/// the `PermissionBoundedDiffView` when `diffBlock != nil`, and the localized
/// secondary-text fallback when nil. SedEdit additionally appends the literal
/// `command` under the fallback (its unique affordance — the user still sees
/// the exact sed command when the substitution can't be previewed).
///
/// This is the AppKit replacement for the STUB `PermissionSedEditCardBodyBuilder`
/// the dispatch (`AppKit/PermissionCard/PermissionCardBodyBuilding.swift`)
/// registered for `.sedEdit`; it does NOT touch the dispatch switch — the
/// integration step removes the matching stub from the spine.
///
/// **The synchronous FS read happens at build time** (in `makeBody` → the data
/// struct's `diffBlock` getter, plan §4.4-5), once per mount, never in a
/// `draw` / `layout` path: `PermissionBoundedDiffView` receives an
/// already-resolved `DiffBlock` and never reads the filesystem.
///
/// 1:1 visual relocation — constants lifted verbatim from
/// `PermissionSedEditCardBody.swift`:
/// - outer VStack(alignment: .leading, spacing: 8) (`:24`)
/// - subtitle `.system(size: 12, weight: .medium)` `.primary`, lineLimit(1),
///   truncationMode(.middle), full-width leading (`:26-31`)
/// - diff cap 240pt, `showsLangBadge`/`showsCopyIcon` false (`:21`, `:34-42`)
/// - fallback `.system(size: 11)` `.secondary` (`:45-46`)
/// - literal command `.system(size: 12, design: .monospaced)` `.primary`,
///   lineLimit(4), truncationMode(.tail), `.textSelection(.enabled)` (`:48-54`)

// MARK: - Body builder (replaces the spine STUB)

/// The real `.sedEdit` body builder. Replaces the STUB declared in
/// `PermissionCardBodyBuilding.swift` (the integration step removes that stub).
struct PermissionSedEditCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // Resolve the per-kind data ONCE — the `diffBlock` getter does the
        // synchronous FS read here, at build time (plan §4.4-5), not in layout.
        let data = PermissionSedEditCardData(request: request)
        return PermissionSedEditCardBodyView(data: data, engine: engine)
    }
}

// MARK: - Data (per-kind getters, lifted VERBATIM from the SwiftUI body)

/// The `.sedEdit` body's pure derivations from `request`. Lifted byte-for-byte
/// from `PermissionSedEditCardBody`'s computed properties
/// (`PermissionSedEditCardBody.swift:61-105`) so the parser wiring, file read,
/// and subtitle formatting stay identical to the SwiftUI body — and so a logic
/// test can drive THIS real production surface (no stub, no re-implementation).
///
/// Cap for the embedded diff. Short substitutions size to their intrinsic
/// height; long ones cap here and scroll (`PermissionSedEditCardBody.diffMaxHeight`).
struct PermissionSedEditCardData {
    let request: PermissionRequest

    /// Cap for the embedded `DiffView` (240pt — `PermissionSedEditCardBody.swift:21`).
    static let diffMaxHeight: CGFloat = 240

    init(request: PermissionRequest) {
        self.request = request
    }

    /// The raw `command` from the request, or `nil` when absent/empty
    /// (`PermissionSedEditCardBody.swift:63-66`).
    var command: String? {
        let raw = request.rawInput["command"] as? String
        return raw?.isEmpty == false ? raw : nil
    }

    /// Parsed substitution info, `nil` when the command doesn't fit the
    /// supported subset (`PermissionSedEditCardBody.swift:72-75`). The body
    /// then falls back to printing the literal command.
    var info: SedEditInfo? {
        guard let command else { return nil }
        return SedEditParser.parse(command)
    }

    /// The target file's basename (`PermissionSedEditCardBody.swift:77-79`).
    var basename: String? {
        info.map { ($0.filePath as NSString).lastPathComponent }
    }

    /// One-line action subtitle `"Edit <basename>"`
    /// (`PermissionSedEditCardBody.swift:81-84`). `nil` when we can't derive a
    /// basename — the body then renders no subtitle.
    var subtitle: String? {
        guard let basename else { return nil }
        return String(localized: "Edit \(basename)")
    }

    /// Constructs the diff: reads the file synchronously, applies the
    /// substitution, hands the old/new text to `DiffBlock`. Returns `nil` when
    /// we can't read the file (`PermissionSedEditCardBody.swift:90-105`) — the
    /// body then falls back to the literal command.
    ///
    /// The FS read lives HERE (build time, called once from `makeBody`), never
    /// in a `draw`/`layout` path (plan §4.4-5).
    var diffBlock: DiffBlock? {
        guard let info else { return nil }
        let oldContent =
            (try? String(contentsOfFile: info.filePath, encoding: .utf8))
            ?? (try? String(contentsOfFile: info.filePath, encoding: .ascii))
        guard let oldContent else { return nil }
        let newContent = info.apply(to: oldContent)
        // Identical pre/post means the substitution didn't match anything —
        // surface the diff anyway so the user sees the file the agent intended
        // to touch. `DiffNSView` renders zero hunks cleanly.
        return DiffBlock(
            filePath: info.filePath,
            oldString: oldContent,
            newString: newContent)
    }
}

// MARK: - Body view

/// The NSView body: optional subtitle, then EITHER the bounded diff (when the
/// substitution previews) OR the localized fallback + literal command.
final class PermissionSedEditCardBodyView: NSView {

    // MARK: - Constants (verbatim from PermissionSedEditCardBody.swift)

    /// Outer stack spacing (`PermissionSedEditCardBody.swift:24`).
    static let stackSpacing: CGFloat = 8
    /// Subtitle font size (`:27`).
    static let subtitleFontSize: CGFloat = 12
    /// Fallback secondary-text font size (`:46`).
    static let fallbackFontSize: CGFloat = 11
    /// Literal-command monospace font size (`:50`).
    static let commandFontSize: CGFloat = 12
    /// Literal-command line cap (`:52`).
    static let commandLineLimit: Int = 4

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The resolved data the view was built from — so a measurement test can
    /// assert the rendered surface against the SAME getters the view read.
    let data: PermissionSedEditCardData
    /// The subtitle label, present only when `data.subtitle != nil`.
    private(set) var subtitleLabel: NSTextField?
    /// The bounded diff view, present only when `data.diffBlock != nil`.
    private(set) var diffView: PermissionBoundedDiffView?
    /// The localized fallback label, present only when `data.diffBlock == nil`.
    private(set) var fallbackLabel: NSTextField?
    /// The literal-command monospace label, present only when
    /// `data.diffBlock == nil && data.command != nil`.
    private(set) var commandLabel: NSTextField?

    private let stack = NSStackView()

    // MARK: - Init

    init(data: PermissionSedEditCardData, engine: SyntaxHighlightEngine?) {
        self.data = data
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        buildArrangedSubviews(engine: engine)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        // Announce the action so VoiceOver doesn't read an unlabeled group when
        // the diff is the only content (sibling FileWrite / Skill convention).
        setAccessibilityLabel(data.subtitle ?? PermissionCardStrings.title(for: data.request))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`. The bounded
    /// diff's highlight Task is cancelled via its own `removeFromSuperview` /
    /// `stop()`, tied to removal, not deinit timing.
    nonisolated deinit {}

    // MARK: - Sizing (regime-B — content drives height; never leak a width up)

    /// The card content stack pins this body to the card column; publish
    /// `noIntrinsicMetric` width so the body never leaks a min-width up to the
    /// full-pane host (plan R1) — height flows from the arranged subviews.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Build

    private func buildArrangedSubviews(engine: SyntaxHighlightEngine?) {
        // subtitle (only when a basename was derived)
        if let subtitle = data.subtitle {
            let label = makeSubtitleLabel(subtitle)
            subtitleLabel = label
            stack.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            label.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        if let diff = data.diffBlock {
            // diff arm — bounded, un-chromed (showsLangBadge/showsCopyIcon false
            // are baked into PermissionBoundedDiffView, plan §4.4-7).
            let view = PermissionBoundedDiffView(
                diff: diff, engine: engine,
                maxHeight: PermissionSedEditCardData.diffMaxHeight)
            diffView = view
            stack.addArrangedSubview(view)
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        } else {
            // nil arm — localized fallback, then the literal command (SedEdit's
            // unique affordance, `PermissionSedEditCardBody.swift:44-55`).
            let fallback = makeFallbackLabel()
            fallbackLabel = fallback
            stack.addArrangedSubview(fallback)
            fallback.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            fallback.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

            if let command = data.command {
                let label = makeCommandLabel(command)
                commandLabel = label
                stack.addArrangedSubview(label)
                label.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
                label.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
        }
    }

    /// `Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)`
    /// `.lineLimit(1).truncationMode(.middle)` (`PermissionSedEditCardBody.swift:26-31`).
    private func makeSubtitleLabel(_ subtitle: String) -> NSTextField {
        let label = NSTextField(labelWithString: subtitle)
        label.font = .systemFont(ofSize: Self.subtitleFontSize, weight: .medium)
        label.textColor = .labelColor  // SwiftUI `.primary`
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle  // SwiftUI `.truncationMode(.middle)`
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        // Hug low so the `==`-pinned label spans the card column and truncates
        // in the middle rather than growing the row to a single long line.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// `Text("Could not preview sed substitution").font(.system(size: 11))`
    /// `.foregroundStyle(.secondary)` (`PermissionSedEditCardBody.swift:45-46`).
    private func makeFallbackLabel() -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString: String(localized: "Could not preview sed substitution"))
        label.font = .systemFont(ofSize: Self.fallbackFontSize)
        label.textColor = .secondaryLabelColor  // SwiftUI `.secondary`
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// `Text(command).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary)`
    /// `.lineLimit(4).truncationMode(.tail).textSelection(.enabled)`
    /// (`PermissionSedEditCardBody.swift:48-54`).
    ///
    /// A selectable, monospaced label capped at 4 lines, tail-truncated. Uses a
    /// wrapping label (so it can flow up to 4 lines) with an explicit max-line
    /// count + tail break mode. Selectable → ⌘C / drag-select like the SwiftUI
    /// `.textSelection(.enabled)`; this label keeps its OWN selection (I-beam)
    /// cursor behavior — only the full-pane card layer view is cursor-rect-free
    /// (plan §4.4-2), descendants are unaffected.
    private func makeCommandLabel(_ command: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: command)
        label.font = .monospacedSystemFont(ofSize: Self.commandFontSize, weight: .regular)
        label.textColor = .labelColor  // SwiftUI `.primary`
        label.maximumNumberOfLines = Self.commandLineLimit  // SwiftUI `.lineLimit(4)`
        label.lineBreakMode = .byTruncatingTail  // SwiftUI `.truncationMode(.tail)`
        label.isSelectable = true  // SwiftUI `.textSelection(.enabled)` (⌘C / drag)
        label.isEditable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
