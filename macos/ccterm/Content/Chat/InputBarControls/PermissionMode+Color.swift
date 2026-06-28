import AppKit
import SwiftUI

extension PermissionMode {
    /// Trigger-pill tint color rendered under the input bar. Mirrors
    /// the CLI's status-bar palette so users see the same visual
    /// signal whether they're in the terminal or the desktop client.
    ///
    /// Mapping comes from ccmaster's `src/utils/permissions/PermissionMode.ts`
    /// (PermissionMode → ModeColorKey), resolved against the light/dark
    /// RGB tables in `src/utils/theme.ts`:
    ///
    /// | Mode               | Token key     | Light          | Dark             |
    /// |--------------------|---------------|----------------|------------------|
    /// | `default`          | `text`        | follows system | follows system   |
    /// | `plan`             | `planMode`    | rgb(0,102,102) | rgb(72,150,140)  |
    /// | `acceptEdits`      | `autoAccept`  | rgb(135,0,255) | rgb(175,135,255) |
    /// | `bypassPermissions`| `error`       | rgb(171,43,63) | rgb(255,107,128) |
    /// | `auto`             | `warning`     | rgb(150,108,30)| rgb(255,193,7)   |
    ///
    /// Popover rows deliberately don't tint — the row label there is
    /// the row's *option*, not the active mode, so coloring it would
    /// preview a state the user hasn't entered yet.
    var triggerTint: Color {
        switch self {
        case .default: return .primary
        case .plan:
            return Self.dynamic(light: (0, 102, 102), dark: (72, 150, 140))
        case .acceptEdits:
            return Self.dynamic(light: (135, 0, 255), dark: (175, 135, 255))
        case .bypassPermissions:
            return Self.dynamic(light: (171, 43, 63), dark: (255, 107, 128))
        case .auto:
            return Self.dynamic(light: (150, 108, 30), dark: (255, 193, 7))
        }
    }

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(Self.dynamicNSColor(light: light, dark: dark))
    }

    /// AppKit `NSColor` analogue of `triggerTint` for the pure-AppKit chrome
    /// row (`ChromeRowView` / `PermissionModePickerController`; migration plan
    /// §4.2). Same RGB tables, same dynamic light/dark resolution — the AppKit
    /// picker tints the trigger label `NSTextField.textColor` with this so it
    /// matches the SwiftUI bar verbatim. `default` resolves to `labelColor`
    /// (the AppKit analogue of SwiftUI `.primary`).
    var triggerTintColor: NSColor {
        switch self {
        case .default: return .labelColor
        case .plan:
            return Self.dynamicNSColor(light: (0, 102, 102), dark: (72, 150, 140))
        case .acceptEdits:
            return Self.dynamicNSColor(light: (135, 0, 255), dark: (175, 135, 255))
        case .bypassPermissions:
            return Self.dynamicNSColor(light: (171, 43, 63), dark: (255, 107, 128))
        case .auto:
            return Self.dynamicNSColor(light: (150, 108, 30), dark: (255, 193, 7))
        }
    }

    private static func dynamicNSColor(light: (Int, Int, Int), dark: (Int, Int, Int)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat(rgb.0) / 255.0,
                green: CGFloat(rgb.1) / 255.0,
                blue: CGFloat(rgb.2) / 255.0,
                alpha: 1.0
            )
        }
    }
}
