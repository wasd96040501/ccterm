import AgentSDK
import AppKit

/// AppKit replacement for the SwiftUI `PermissionFilesystemReadCardBody`
/// (`PermissionFilesystemReadCardBody.swift`) — the body for `.filesystemRead`
/// permission requests (Read / Glob / Grep / FileRead). A 1:1 visual relocation
/// of the SwiftUI `HStack(.top) { icon ; VStack(.leading) { label, primary,
/// secondary } }`, with the per-kind data getters lifted VERBATIM from the
/// original (`toolName` / `toolLabel` / `iconName` / `primary` / `secondary`).
///
/// Constants lifted verbatim from `PermissionFilesystemReadCardBody.swift`:
/// - outer HStack(alignment:.top, spacing:8) (`:18`)
/// - icon: `.system(size: 12)` `.secondary` (secondaryLabelColor), inside a
///   14pt-wide centered frame (`:19-22`)
/// - VStack(alignment:.leading, spacing:4), maxWidth leading (`:23,46`)
/// - tool label: `.system(size: 12, weight: .medium)` `.primary` (`:25-27`)
/// - primary (optional): `.system(size: 12, design: .monospaced)` `.primary`,
///   lineLimit 2, `.middle` truncation, selectable (`:28-34`)
/// - secondary (optional): `.system(size: 11, design: .monospaced)`
///   `.secondary`, lineLimit 1, `.middle` truncation, selectable (`:36-43`)
///
/// `.textSelection(.enabled)` ⇒ the two monospace lines are selectable
/// `NSTextField` labels (read-only, no IME). The body owns no Task and does no
/// FS read — `engine` is ignored (this is not a diff-family body).
///
/// Conforms to `PermissionCardBodyBuilding` via
/// `PermissionFilesystemReadCardBodyBuilder` (replacing the spine STUB at
/// integration). The view is the testable surface — its data getters are the
/// VERBATIM per-kind getters the original body exposed.
final class PermissionFilesystemReadCardBodyView: NSView {

    // MARK: - Constants (verbatim from PermissionFilesystemReadCardBody.swift)

    /// Outer HStack spacing (`:18`).
    static let rowSpacing: CGFloat = 8
    /// VStack spacing (`:23`).
    static let columnSpacing: CGFloat = 4
    /// Icon frame width (`:22`).
    static let iconFrameWidth: CGFloat = 14
    /// Icon point size (`:20`).
    static let iconSize: CGFloat = 12
    /// Tool label / primary line font size (`:26,29`).
    static let primaryFontSize: CGFloat = 12
    /// Secondary line font size (`:38`).
    static let secondaryFontSize: CGFloat = 11
    /// Primary line max lines (`:31`).
    static let primaryLineLimit = 2
    /// Secondary line max lines (`:41`).
    static let secondaryLineLimit = 1

    // MARK: - Inputs

    let request: PermissionRequest

    // MARK: - Subviews

    private let iconView = NSImageView()
    private let column = NSStackView()
    private let labelField = NSTextField(labelWithString: "")
    private var primaryField: NSTextField?
    private var secondaryField: NSTextField?

    // MARK: - Init

    init(request: PermissionRequest) {
        self.request = request
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        configureIcon()
        configureColumn()
        layoutSubviewsForBody()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(toolLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Sizing (regime-B — the card column drives the width; content the height)

    /// Publish `noIntrinsicMetric` width so the body never leaks a min-width up
    /// to the full-pane card host (plan R1) — the headline / monospace lines are
    /// pinned leading+trailing across the body, so without this override their
    /// content widths could surface as a body min-width. Height flows from the
    /// icon + text-column constraints.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The headline label text, as rendered.
    var renderedToolLabel: String { labelField.stringValue }
    /// The primary monospace line, as rendered (nil when the row is absent).
    var renderedPrimary: String? { primaryField?.stringValue }
    /// The secondary monospace line, as rendered (nil when the row is absent).
    var renderedSecondary: String? { secondaryField?.stringValue }
    /// The icon symbol the view was built with — `iconName` is the verbatim
    /// per-tool getter, but this proves it reached the `NSImageView`.
    var renderedIconSymbol: String { iconName }
    /// The primary field's max line count (2 for parity with the SwiftUI
    /// `lineLimit(2)`); nil when the row is absent.
    var primaryMaxLines: Int? { primaryField?.maximumNumberOfLines }
    /// The secondary field's max line count (1).
    var secondaryMaxLines: Int? { secondaryField?.maximumNumberOfLines }

    // MARK: - Configuration

    private func configureIcon() {
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.iconSize, weight: .regular))
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageAlignment = .alignCenter
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        // 14pt-wide centered frame (SwiftUI `.frame(width: 14, alignment:
        // .center)`); width fixed, never compressed/stretched.
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconFrameWidth),
        ])
    }

    private func configureColumn() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Self.columnSpacing
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            // HStack spacing 8 between the icon frame and the text column.
            column.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor, constant: Self.rowSpacing),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Build the headline + optional primary/secondary monospace rows. The
    /// optional rows match the SwiftUI `if let primary`/`if let secondary`
    /// branches — collapsed (no view) when the field is missing/empty.
    private func layoutSubviewsForBody() {
        // Tool label — size-12 medium, primary (labelColor).
        labelField.stringValue = toolLabel
        labelField.font = .systemFont(ofSize: Self.primaryFontSize, weight: .medium)
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1
        labelField.translatesAutoresizingMaskIntoConstraints = false
        addArranged(labelField)

        if let primary = primary {
            let field = makeMonospaceField(
                primary,
                fontSize: Self.primaryFontSize,
                color: .labelColor,
                maxLines: Self.primaryLineLimit)
            primaryField = field
            addArranged(field)
        }

        if let secondary = secondary {
            let field = makeMonospaceField(
                secondary,
                fontSize: Self.secondaryFontSize,
                color: .secondaryLabelColor,
                maxLines: Self.secondaryLineLimit)
            secondaryField = field
            addArranged(field)
        }
    }

    /// Add an arranged subview pinned to the column's leading + trailing so the
    /// monospace lines span the full body width and `.middle`-truncate within it
    /// (SwiftUI `.frame(maxWidth: .infinity, alignment: .leading)`).
    private func addArranged(_ view: NSView) {
        column.addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
    }

    /// A read-only, user-selectable monospaced label (`.textSelection(.enabled)`)
    /// with `.middle` truncation and a fixed line limit. `isSelectable = true` +
    /// label (not editable) ⇒ ⌘C works, no IME marked text.
    private func makeMonospaceField(
        _ text: String, fontSize: CGFloat, color: NSColor, maxLines: Int
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        field.textColor = color
        field.maximumNumberOfLines = maxLines
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.truncatesLastVisibleLine = true
        field.isSelectable = true
        field.isEditable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        // Hug low so the field stretches to the column's full leading-aligned
        // width (giving the truncation a bounded width to clip inside) rather
        // than sizing to its single-line intrinsic width and never truncating.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    // MARK: - Data (verbatim from PermissionFilesystemReadCardBody.swift:51-126)

    /// `Read` / `Glob` / `Grep` / `FileRead` are the only inputs `kind(for:)`
    /// routes here. We expose the literal tool name so tests can pin per-tool
    /// behaviour without a re-derived enum.
    var toolName: String { request.toolName }

    /// Headline label for the tool: localised, sentence-case verb. `Read` and
    /// `FileRead` are surfaced as "Read" since upstream uses the same
    /// `userFacingName`.
    var toolLabel: String {
        switch toolName {
        case "Glob": return String(localized: "Glob")
        case "Grep": return String(localized: "Grep")
        default: return String(localized: "Read")
        }
    }

    /// SF Symbols icon that visually matches the operation. Read = document,
    /// Glob = file-search wildcard, Grep = magnifying glass on text.
    var iconName: String {
        switch toolName {
        case "Glob": return "doc.text.magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        default: return "doc.text"
        }
    }

    /// Primary monospace line — the main thing the agent wants to touch. Read →
    /// `file_path`; Glob/Grep → the `pattern`. Returns `nil` when the field is
    /// missing or empty so the body renders the headline alone instead of an "—"
    /// placeholder.
    var primary: String? {
        switch toolName {
        case "Glob", "Grep":
            return string(forKeys: ["pattern"])
        default:
            return string(forKeys: ["file_path", "filePath", "path"])
        }
    }

    /// Secondary monospace line, prefixed `path:` / `mode:` (the `mode:` value is
    /// the `output_mode` / `outputMode` field) so the user can tell which knob is
    /// which. Glob/Grep only — Read has nothing useful to put here.
    var secondary: String? {
        switch toolName {
        case "Glob":
            if let path = string(forKeys: ["path"]) {
                return String(localized: "path: \(path)")
            }
            return nil
        case "Grep":
            var parts: [String] = []
            if let path = string(forKeys: ["path"]) {
                parts.append(String(localized: "path: \(path)"))
            }
            if let mode = string(forKeys: ["output_mode", "outputMode"]) {
                parts.append(String(localized: "mode: \(mode)"))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        default:
            return nil
        }
    }

    /// Pull the first non-empty string for any of `keys` — covers snake_case
    /// (current CLI) and camelCase (older builds).
    private func string(forKeys keys: [String]) -> String? {
        for key in keys {
            if let v = request.rawInput[key] as? String, !v.isEmpty {
                return v
            }
        }
        return nil
    }
}

// MARK: - Body builder (replaces the spine STUB at integration)

/// The real `.filesystemRead` body builder — replaces the empty-`NSView()` STUB
/// the spine registered in `PermissionCardBodyBuilding.swift`. Constructs a
/// fresh `PermissionFilesystemReadCardBodyView` per mount; `engine` is ignored
/// (this body owns no highlight Task / FS read).
struct PermissionFilesystemReadCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        PermissionFilesystemReadCardBodyView(request: request)
    }
}
