import AppKit

/// Xcode's code review mark at a diff's leading edge (preview.css `.src .bar`):
/// a 3-pt bar down each run of changed lines, rounded where the run starts and
/// ends. A document's gutter and an approval card's diff draw the same one.
public enum ChangeBar: Equatable {
    /// Source-control blue, hatched, one per hunk — removed and added lines
    /// together.
    case hunks
    /// In green, the file's full height: all of it is new.
    case wholeFile

    public static let width: CGFloat = 3

    /// One line's part of a run, `segment` wide and tall: it runs on into the
    /// lines above and below when they carry the bar too, and is rounded where
    /// they don't.
    public func draw(_ segment: NSRect, joinsAbove: Bool, joinsBelow: Bool) {
        let radius = segment.width / 2
        var shape = segment
        if joinsAbove {
            shape.origin.y -= radius
            shape.size.height += radius
        }
        if joinsBelow { shape.size.height += radius }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: segment).addClip()
        NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).addClip()
        switch self {
        case .wholeFile:
            NSColor.systemGreen.withAlphaComponent(0.7).setFill()
            segment.fill()
        case .hunks:
            NSColor.systemBlue.withAlphaComponent(0.45).setFill()
            segment.fill()
            NSColor.systemBlue.setStroke()
            let stripes = NSBezierPath()
            stripes.lineWidth = 1.5
            // On a 3-pt pitch from y = 0, so a run's segments line up.
            let pitch = segment.width
            var y = (segment.minY / pitch).rounded(.down) * pitch - pitch
            while y < segment.maxY + pitch {
                stripes.move(to: NSPoint(x: segment.minX, y: y + pitch))
                stripes.line(to: NSPoint(x: segment.maxX, y: y))
                y += pitch
            }
            stripes.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The washes a diff lays across a whole changed line (preview.css `--add-bg`,
/// `--del-bg`).
extension NSColor {
    public static let addedLineWash = NSColor.wash(.systemGreen, light: 0.14, dark: 0.15)
    public static let removedLineWash = NSColor.wash(.systemRed, light: 0.10, dark: 0.14)
}
