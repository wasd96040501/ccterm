import AppKit

extension NSImage {
    /// An SF Symbol at a point size and weight, made once per process: rows
    /// ask for the same few on every configure, and building one is most of
    /// what configuring a work line costs. The image view tints it.
    @MainActor
    public static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = SymbolKey(name: name, pointSize: pointSize, weight: weight.rawValue)
        if let image = symbols[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(SymbolConfiguration(pointSize: pointSize, weight: weight))
        symbols[key] = image
        return image
    }

    private struct SymbolKey: Hashable {
        var name: String
        var pointSize: CGFloat
        var weight: CGFloat
    }

    @MainActor private static var symbols: [SymbolKey: NSImage] = [:]
}
