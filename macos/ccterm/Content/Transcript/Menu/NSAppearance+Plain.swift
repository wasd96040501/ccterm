import AppKit

extension NSAppearance {
    /// Light or Dark without the vibrancy a visual effect view gives its
    /// subviews. On the menu material the effective appearance is vibrant, and
    /// there a system colour (`separatorColor`, `quaternarySystemFill`)
    /// resolves to an opaque grey meant to be blended with the material — a
    /// layer painted with it shows that grey instead: the separator vanishes
    /// in Light and turns dark in Dark. A layer's colour is resolved in this one.
    var plain: NSAppearance {
        NSAppearance(named: bestMatch(from: [.aqua, .darkAqua]) ?? .aqua) ?? self
    }
}
