import AppKit
import Components
import DisplayModels

/// What the families share (design/transcript, *1 · The run row* and the
/// rows that answer): the tile in every state, at 2× as the sheet shows it,
/// and the pill button rows and documents answer with.
enum DrawingSpecimen {
    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "Drawing",
            note:
                "A tile is a 16-pt Lamé squircle (n = 4, the sidebar's family) with the glyph of what the work was; "
                + "its state is drawn on the tile itself — streaming at half ink, a travelling arc while it runs, a "
                + "dashed turning outline in the background, coral while it waits for you, red when it failed, a stop "
                + "square when it was denied — never elsewhere on the row. A pill button is 22 tall, a quaternary fill "
                + "under a hairline ring, or the accent under white ink; its key follows, dimmed.",
            specimens: [
                // The design's fluid parts: as wide as the sheet's card.
                .init(title: "Tiles, shown at 2× — states change the tile, never the row", view: TileGrid()),
                .init(title: "Pill buttons — plain, primary, with a key, off", view: buttons()),
            ])
    }

    /// As the rows put them: a choice beside its primary answer.
    private static func buttons() -> NSView {
        let off = PillButton(title: "Allow", keys: "⌘↩", isPrimary: true)
        off.isEnabled = false
        // Each button its own width; what is left of the card stays empty.
        let rest = NSView()
        rest.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [
            PillButton(title: "Keep Planning"), PillButton(title: "Approve", keys: "⌘↩", isPrimary: true),
            PillButton(title: "Deny", keys: "⎋"), PillButton(title: "Open"), off, rest,
        ])
        row.spacing = 8
        // The sheet's `padding: 16px 24px`, as the tile grid has it.
        return AccountsSpecimen.inset(row, by: 24)
    }
}

/// The sheet's `.tilegrid`: a kind per row under a state per column, the
/// kind's name in a 120-pt column and the states sharing the rest equally.
private final class TileGrid: NSView {
    private static let kinds: [(String, ToolKind)] = [
        ("command", .command), ("change", .change), ("create", .create), ("read", .read), ("search", .search),
        ("web", .web), ("agent", .agent), ("tasks", .tasks), ("schedule", .schedule), ("message", .message),
        ("other", .other),
    ]
    private static let states: [(String, Tile.State)] = [
        ("done", .done), ("preparing", .preparing), ("running", .running), ("background", .background),
        ("waiting for you", .waiting), ("failed", .failed), ("denied · interrupted", .stopped),
    ]

    init() {
        super.init(frame: .zero)
        let header = Self.row(
            title: "", cells: Self.states.map { Self.label($0.0, weight: .semibold, color: .labelColor) })
        let rows = Self.kinds.map { name, kind in
            Self.row(title: name, cells: Self.states.map { ScaledTile(Tile(glyph: .tool(kind), state: $0.1)) })
        }
        let grid = NSStackView(views: [header] + rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        for row in [header] + rows {
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        // The sheet's `padding: 16px 24px`.
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// `title` in the 120-pt column, then `cells` in equal columns, each
    /// centred in its own.
    private static func row(title: String, cells: [NSView]) -> NSStackView {
        let name = label(title, weight: .regular, color: .secondaryLabelColor)
        name.alignment = .natural
        name.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let columns = NSStackView(views: cells.map(centred))
        columns.distribution = .fillEqually
        columns.spacing = 8
        let row = NSStackView(views: [name, columns])
        row.spacing = 8
        return row
    }

    private static func centred(_ view: NSView) -> NSView {
        let cell = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            view.topAnchor.constraint(equalTo: cell.topAnchor),
            view.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor),
        ])
        return cell
    }

    /// The sheet's 11-pt grid text.
    private static func label(_ text: String, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// A tile drawn at twice its size, in a 36-pt cell: its bounds half its
/// frame, so the tile draws as it does in a row, only larger.
private final class ScaledTile: NSView {
    init(_ tile: Tile) {
        super.init(frame: .zero)
        let view = TileView()
        view.tile = tile
        addSubview(view)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Bounds half the frame, whatever frame layout gives it, and the tile
    /// centred in them at its own 16 pt.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let half = NSSize(width: newSize.width / 2, height: newSize.height / 2)
        setBoundsSize(half)
        subviews.first?.frame = NSRect(x: (half.width - 16) / 2, y: (half.height - 16) / 2, width: 16, height: 16)
    }
}
