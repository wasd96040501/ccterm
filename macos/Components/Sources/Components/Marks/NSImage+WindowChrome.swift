import AppKit

/// The window chrome the design sheets' window mocks draw (`design/window-chrome`), from the
/// package's catalogue. The three lights are full colour; `windowChromeInactive` and
/// `windowChromeLight` are template images (tint them with the tertiary label).
extension NSImage {
    public static var windowChromeClose: NSImage { Bundle.module.image(forResource: "WindowChromeClose") ?? NSImage() }
    public static var windowChromeInactive: NSImage {
        Bundle.module.image(forResource: "WindowChromeInactive") ?? NSImage()
    }
    public static var windowChromeLight: NSImage { Bundle.module.image(forResource: "WindowChromeLight") ?? NSImage() }
    public static var windowChromeMinimize: NSImage {
        Bundle.module.image(forResource: "WindowChromeMinimize") ?? NSImage()
    }
    public static var windowChromeZoom: NSImage { Bundle.module.image(forResource: "WindowChromeZoom") ?? NSImage() }
}
