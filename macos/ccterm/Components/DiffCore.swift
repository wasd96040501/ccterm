import AppKit
import SwiftUI

// MARK: - Diff Engine

/// Pure-function unified diff engine. Consumed by both the SwiftUI
/// ``NativeDiffView`` (NSTextView-backed) and the AppKit ``DiffRow``
/// (Core Text self-drawn in the native transcript).
enum DiffEngine {

    struct Line {
        enum LineType { case context, add, del }
        let type: LineType
        let content: String
        let lineNo: Int?
    }

    struct Hunk {
        let oldStart: Int
        let newStart: Int
        let lines: [Line]
    }

    static func computeHunks(old: String, new: String, context: Int = 3) -> [Hunk] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        let diff = newLines.difference(from: oldLines)

        var removedSet = Set<Int>()
        var insertedSet = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedSet.insert(offset)
            case .insert(let offset, _, _): insertedSet.insert(offset)
            }
        }

        // Build flat diff output: deletions before insertions at each position
        var flat: [(Character, String)] = []
        var oi = 0, ni = 0
        while oi < oldLines.count || ni < newLines.count {
            while oi < oldLines.count, removedSet.contains(oi) {
                flat.append(("-", oldLines[oi])); oi += 1
            }
            while ni < newLines.count, insertedSet.contains(ni) {
                flat.append(("+", newLines[ni])); ni += 1
            }
            if oi < oldLines.count, ni < newLines.count {
                flat.append((" ", newLines[ni])); oi += 1; ni += 1
            }
        }

        return groupHunks(flat, context: context)
    }

    // MARK: Private

    private static func splitLines(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        return s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func groupHunks(_ lines: [(Character, String)], context: Int) -> [Hunk] {
        let changes = lines.indices.filter { lines[$0].0 != " " }
        guard !changes.isEmpty else { return [] }

        // Merge nearby change groups
        var groups: [(Int, Int)] = []
        var gs = changes[0], ge = changes[0]
        for i in 1..<changes.count {
            if changes[i] - ge <= 2 * context {
                ge = changes[i]
            } else {
                groups.append((gs, ge)); gs = changes[i]; ge = changes[i]
            }
        }
        groups.append((gs, ge))

        return groups.map { group in
            let lo = max(0, group.0 - context)
            let hi = min(lines.count, group.1 + context + 1)

            // Starting line numbers for this hunk
            var oldLine = 1, newLine = 1
            for i in 0..<lo {
                switch lines[i].0 {
                case " ": oldLine += 1; newLine += 1
                case "-": oldLine += 1
                case "+": newLine += 1
                default: break
                }
            }

            var hunkLines: [Line] = []
            var curOld = oldLine, curNew = newLine
            for i in lo..<hi {
                let (ch, content) = lines[i]
                switch ch {
                case " ":
                    hunkLines.append(Line(type: .context, content: content, lineNo: curNew))
                    curOld += 1; curNew += 1
                case "+":
                    hunkLines.append(Line(type: .add, content: content, lineNo: curNew))
                    curNew += 1
                case "-":
                    hunkLines.append(Line(type: .del, content: content, lineNo: curOld))
                    curOld += 1
                default: break
                }
            }

            return Hunk(oldStart: oldLine, newStart: newLine, lines: hunkLines)
        }
    }
}

// MARK: - Colors

/// Shared diff palette. SwiftUI `Color` variants for ``NativeDiffView``;
/// `NSColor` variants for AppKit-native consumers (DiffRow) that paint via
/// `CGContext` and want to skip the `NSColor(Color(...))` bridge allocation
/// on every paint.
///
/// Values in both variants are identical sRGB tuples — keep them in sync.
enum DiffColors {

    // MARK: SwiftUI Color (SwiftUI consumers)

    static func tableBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 27/255, green: 31/255, blue: 38/255)
            : Color(.sRGB, red: 129/255, green: 139/255, blue: 152/255, opacity: 31/255)
    }

    static func gutterText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 230/255, green: 237/255, blue: 243/255, opacity: 0.4)
            : Color(.sRGB, red: 31/255, green: 35/255, blue: 40/255, opacity: 0.5)
    }

    static func signAdd(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 63/255, green: 185/255, blue: 80/255)
            : Color(.sRGB, red: 26/255, green: 127/255, blue: 55/255)
    }

    static func signDel(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 248/255, green: 81/255, blue: 73/255)
            : Color(.sRGB, red: 207/255, green: 34/255, blue: 46/255)
    }

    static func gutterBg(_ type: DiffEngine.Line.LineType, _ scheme: ColorScheme) -> Color {
        switch (type, scheme) {
        case (.add, .dark):      Color(.sRGB, red: 63/255, green: 185/255, blue: 80/255, opacity: 0.25)
        case (.add, .light):     Color(.sRGB, red: 214/255, green: 236/255, blue: 222/255)
        case (.del, .dark):      Color(.sRGB, red: 248/255, green: 81/255, blue: 73/255, opacity: 0.25)
        case (.del, .light):     Color(.sRGB, red: 236/255, green: 214/255, blue: 216/255)
        case (.context, .dark):  Color.white.opacity(0.04)
        case (.context, .light): Color.black.opacity(0.04)
        default: .clear
        }
    }

    static func contentBg(_ type: DiffEngine.Line.LineType, _ scheme: ColorScheme) -> Color {
        switch (type, scheme) {
        case (.add, .dark):  Color(.sRGB, red: 63/255, green: 185/255, blue: 80/255, opacity: 0.15)
        case (.add, .light): Color(.sRGB, red: 230/255, green: 243/255, blue: 235/255)
        case (.del, .dark):  Color(.sRGB, red: 248/255, green: 81/255, blue: 73/255, opacity: 0.15)
        case (.del, .light): Color(.sRGB, red: 243/255, green: 230/255, blue: 231/255)
        default: .clear
        }
    }

    static func separatorBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 48/255, green: 54/255, blue: 61/255)
            : Color(.sRGB, red: 209/255, green: 217/255, blue: 224/255)
    }

    static func separatorFg(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 230/255, green: 237/255, blue: 243/255, opacity: 0.3)
            : Color(.sRGB, red: 31/255, green: 35/255, blue: 40/255, opacity: 0.4)
    }

    // MARK: NSColor (AppKit-native consumers)

    static func nsTableBg(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(srgbRed: 27/255, green: 31/255, blue: 38/255, alpha: 1)
            : NSColor(srgbRed: 129/255, green: 139/255, blue: 152/255, alpha: 31/255)
    }

    static func nsGutterText(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(srgbRed: 230/255, green: 237/255, blue: 243/255, alpha: 0.4)
            : NSColor(srgbRed: 31/255, green: 35/255, blue: 40/255, alpha: 0.5)
    }

    static func nsSignAdd(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(srgbRed: 63/255, green: 185/255, blue: 80/255, alpha: 1)
            : NSColor(srgbRed: 26/255, green: 127/255, blue: 55/255, alpha: 1)
    }

    static func nsSignDel(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(srgbRed: 248/255, green: 81/255, blue: 73/255, alpha: 1)
            : NSColor(srgbRed: 207/255, green: 34/255, blue: 46/255, alpha: 1)
    }

    static func nsGutterBg(_ type: DiffEngine.Line.LineType, isDark: Bool) -> NSColor {
        switch (type, isDark) {
        case (.add, true):      NSColor(srgbRed: 63/255, green: 185/255, blue: 80/255, alpha: 0.25)
        case (.add, false):     NSColor(srgbRed: 214/255, green: 236/255, blue: 222/255, alpha: 1)
        case (.del, true):      NSColor(srgbRed: 248/255, green: 81/255, blue: 73/255, alpha: 0.25)
        case (.del, false):     NSColor(srgbRed: 236/255, green: 214/255, blue: 216/255, alpha: 1)
        case (.context, true):  NSColor(white: 1, alpha: 0.04)
        case (.context, false): NSColor(white: 0, alpha: 0.04)
        }
    }

    static func nsContentBg(_ type: DiffEngine.Line.LineType, isDark: Bool) -> NSColor {
        switch (type, isDark) {
        case (.add, true):  NSColor(srgbRed: 63/255, green: 185/255, blue: 80/255, alpha: 0.15)
        case (.add, false): NSColor(srgbRed: 230/255, green: 243/255, blue: 235/255, alpha: 1)
        case (.del, true):  NSColor(srgbRed: 248/255, green: 81/255, blue: 73/255, alpha: 0.15)
        case (.del, false): NSColor(srgbRed: 243/255, green: 230/255, blue: 231/255, alpha: 1)
        case (.context, _): .clear
        }
    }

    static func nsSeparatorBg(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(srgbRed: 48/255, green: 54/255, blue: 61/255, alpha: 1)
            : NSColor(srgbRed: 209/255, green: 217/255, blue: 224/255, alpha: 1)
    }

    static func nsSeparatorFg(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(srgbRed: 230/255, green: 237/255, blue: 243/255, alpha: 0.3)
            : NSColor(srgbRed: 31/255, green: 35/255, blue: 40/255, alpha: 0.4)
    }

    // MARK: - Dynamic NSColor (appearance-aware, resolved at draw time)

    private static func dyn(_ build: @escaping (Bool) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            build(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
    }

    static let dynamicTableBg: NSColor = dyn(nsTableBg(isDark:))
    static let dynamicGutterText: NSColor = dyn(nsGutterText(isDark:))
    static let dynamicSignAdd: NSColor = dyn(nsSignAdd(isDark:))
    static let dynamicSignDel: NSColor = dyn(nsSignDel(isDark:))

    static let dynamicGutterBgAdd: NSColor = dyn { nsGutterBg(.add, isDark: $0) }
    static let dynamicGutterBgDel: NSColor = dyn { nsGutterBg(.del, isDark: $0) }
    static let dynamicGutterBgContext: NSColor = dyn { nsGutterBg(.context, isDark: $0) }

    static let dynamicContentBgAdd: NSColor = dyn { nsContentBg(.add, isDark: $0) }
    static let dynamicContentBgDel: NSColor = dyn { nsContentBg(.del, isDark: $0) }

    static let dynamicSeparatorBg: NSColor = dyn(nsSeparatorBg(isDark:))
    static let dynamicSeparatorFg: NSColor = dyn(nsSeparatorFg(isDark:))

    /// Convenience: full-width line background by line type.
    static func dynamicContentBg(_ type: DiffEngine.Line.LineType) -> NSColor {
        switch type {
        case .add: return dynamicContentBgAdd
        case .del: return dynamicContentBgDel
        case .context: return .clear
        }
    }

    /// Convenience: gutter background by line type.
    static func dynamicGutterBg(_ type: DiffEngine.Line.LineType) -> NSColor {
        switch type {
        case .add: return dynamicGutterBgAdd
        case .del: return dynamicGutterBgDel
        case .context: return dynamicGutterBgContext
        }
    }
}
