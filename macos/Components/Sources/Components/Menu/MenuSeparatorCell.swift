import AppKit

/// A hairline between groups (`.msep`): 5 above and under, 15 in from either side.
final class MenuSeparatorCell: NSTableCellView {
    private let line = MenuHairline()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.trailingInset),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
