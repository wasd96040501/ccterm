import AppKit

extension NSImage {
    /// An SF Symbol at a point size, weight and scale, made once per process:
    /// rows ask for the same few on every configure, and building one is most
    /// of what configuring a work line costs. The image view tints it.
    @MainActor
    public static func symbol(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, scale: SymbolScale = .medium
    ) -> NSImage? {
        let key = SymbolKey(name: name, pointSize: pointSize, weight: weight.rawValue, scale: scale.rawValue)
        if let image = symbols[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(SymbolConfiguration(pointSize: pointSize, weight: weight, scale: scale))
        symbols[key] = image
        return image
    }

    private struct SymbolKey: Hashable {
        var name: String
        var pointSize: CGFloat
        var weight: CGFloat
        var scale: Int
    }

    @MainActor private static var symbols: [SymbolKey: NSImage] = [:]
}
