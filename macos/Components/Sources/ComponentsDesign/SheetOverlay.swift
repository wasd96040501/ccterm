import AppKit

/// A sheet over its window, as the design shows one (design/settings,
/// `.layer.scrim` and `.sheet`): a faint scrim over the whole window, the
/// sheet 14 below its top, centred, 18-pt corners, a hairline edge and its
/// shadows. The scrim takes every click, as a modal sheet does.
final class SheetOverlay: NSView {
    /// The sheet's distance from the window's top.
    static let topMargin: CGFloat = 14

    /// `sheet` at `size`, the content of the sheet's surface.
    init(sheet: NSView, size: NSSize) {
        super.init(frame: .zero)
        wantsLayer = true
        // A sheet is a window: the real window's colour, not the design's
        // #fff and #282828.
        let surface = ElevatedView(
            radius: 18, fill: .windowBackgroundColor,
            shadow: .init(
                ring: (.design(white: 0, alpha: 0.16), .design(white: 0, alpha: 0.8)),
                innerRing: .design(white: 1, alpha: 0.12),
                drops: [
                    (18, 50, .design(white: 0, alpha: 0.22), .design(white: 0, alpha: 0.5)),
                    (4, 12, .design(white: 0, alpha: 0.08), .design(white: 0, alpha: 0)),
                ]))
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        sheet.translatesAutoresizingMaskIntoConstraints = false
        surface.content.addSubview(sheet)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor, constant: Self.topMargin),
            surface.centerXAnchor.constraint(equalTo: centerXAnchor),
            surface.widthAnchor.constraint(equalToConstant: size.width),
            surface.heightAnchor.constraint(equalToConstant: size.height),
            sheet.topAnchor.constraint(equalTo: surface.content.topAnchor),
            sheet.bottomAnchor.constraint(equalTo: surface.content.bottomAnchor),
            sheet.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // `.layer.scrim`: `rgba(0, 0, 0, .06)`.
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.06).cgColor
    }
}
