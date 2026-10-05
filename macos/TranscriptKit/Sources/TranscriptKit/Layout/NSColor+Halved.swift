import AppKit

extension NSColor {

    /// This colour at half its alpha, still following the appearance — how a
    /// pending bubble is drawn. A paint list has no opacity of its own, so the
    /// bubble halves every colour it emits rather than the surface's.
    var halved: NSColor {
        NSColor(name: nil) { appearance in
            var resolved = self
            appearance.performAsCurrentDrawingAppearance {
                resolved = self.withAlphaComponent(self.alphaComponent * 0.5)
            }
            return resolved
        }
    }
}
