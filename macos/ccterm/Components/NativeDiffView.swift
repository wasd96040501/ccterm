import SwiftUI

/// Native SwiftUI unified diff view with syntax highlighting via highlight.js (JSCore).
/// Uses NSTextView (TextKit 1) for full-width line backgrounds without padding hacks.
struct NativeDiffView: View {
    let filePath: String
    let oldString: String
    let newString: String
    var maxHeight: CGFloat? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.syntaxEngine) private var syntaxEngine

    @State private var hunks: [DiffEngine.Hunk] = []
    @State private var lineHighlights: [String: [SyntaxToken]] = [:]
    @State private var cachedContent = NSAttributedString(string: " ")
    @State private var containerWidth: CGFloat = 0
    @State private var contentHeight: CGFloat?

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            DiffTextRepresentable(attributedString: cachedContent, minWidth: containerWidth)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: DiffContentHeightKey.self, value: geo.size.height)
                })
        }
        .defaultScrollAnchor(.topLeading)
        .scrollIndicators(.never)
        .onPreferenceChange(DiffContentHeightKey.self) { contentHeight = $0 }
        .frame(height: resolvedHeight)
        .background {
            GeometryReader { geo in
                Color.clear.onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in containerWidth = new }
            }
        }
        .background(DiffColors.tableBg(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: "\(oldString.hashValue)_\(newString.hashValue)") {
            hunks = DiffEngine.computeHunks(old: oldString, new: newString)
            rebuildAttributedContent()

            guard let engine = syntaxEngine else { return }
            let lang = LanguageDetection.language(for: filePath)

            let uniqueContents = Set(hunks.flatMap(\.lines).map(\.content)).filter { !$0.isEmpty }
            for content in uniqueContents {
                let tokens = await engine.highlight(code: content, language: lang)
                lineHighlights[content] = tokens
            }
            rebuildAttributedContent()
        }
        .onChange(of: colorScheme) {
            rebuildAttributedContent()
        }
    }

    private var resolvedHeight: CGFloat? {
        guard let maxHeight else { return nil }
        guard let contentHeight else { return maxHeight }
        return min(contentHeight, maxHeight)
    }

    // MARK: - NSAttributedString Builder

    private func rebuildAttributedContent() {
        guard !hunks.isEmpty else {
            cachedContent = NSAttributedString(string: " ")
            return
        }

        let maxLineNo = hunks.flatMap(\.lines).compactMap(\.lineNo).max() ?? 0
        let gutterDigits = max(2, String(maxLineNo).count)

        let result = NSMutableAttributedString()

        for (hi, hunk) in hunks.enumerated() {
            if hi > 0 {
                result.append(buildSeparator(gutterDigits: gutterDigits))
            }
            for line in hunk.lines {
                result.append(buildLine(line, gutterDigits: gutterDigits))
            }
        }

        // Remove trailing newline
        if result.length > 0, result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }

        cachedContent = result
    }

    private func buildLine(
        _ line: DiffEngine.Line,
        gutterDigits: Int
    ) -> NSAttributedString {
        let font = Self.font
        let lineNoStr = line.lineNo.map(String.init) ?? ""
        let paddedLineNo = String(repeating: " ", count: max(0, gutterDigits - lineNoStr.count)) + lineNoStr

        let sign: String
        let signColor: NSColor
        switch line.type {
        case .add:     sign = "+"; signColor = NSColor(DiffColors.signAdd(colorScheme))
        case .del:     sign = "-"; signColor = NSColor(DiffColors.signDel(colorScheme))
        case .context: sign = " "; signColor = .clear
        }

        let gutterBg = NSColor(DiffColors.gutterBg(line.type, colorScheme))
        let contentBg = NSColor(DiffColors.contentBg(line.type, colorScheme))

        let result = NSMutableAttributedString()

        // Gutter: " {lineNo} "
        result.append(NSAttributedString(string: " \(paddedLineNo) ", attributes: [
            .font: font,
            .foregroundColor: NSColor(DiffColors.gutterText(colorScheme)),
            .diffGutterBackground: gutterBg,
        ]))

        // Sign: " {sign} "
        result.append(NSAttributedString(string: " \(sign) ", attributes: [
            .font: font,
            .foregroundColor: signColor,
        ]))

        // Content (highlighted or plain)
        let rawContent = line.content.isEmpty ? " " : line.content
        if let tokens = lineHighlights[line.content], !line.content.isEmpty {
            result.append(SyntaxAttributedString.buildNS(
                tokens: tokens, colorScheme: colorScheme, font: font
            ))
        } else {
            result.append(NSAttributedString(string: rawContent, attributes: [
                .font: font,
                .foregroundColor: NSColor(SyntaxTheme.plainColor(colorScheme)),
            ]))
        }

        // Trailing space for visual padding
        result.append(NSAttributedString(string: " ", attributes: [.font: font]))

        // Newline
        result.append(NSAttributedString(string: "\n", attributes: [.font: font]))

        // Full-width line background on entire line
        let lineRange = NSRange(location: 0, length: result.length)
        result.addAttribute(.diffLineBackground, value: contentBg, range: lineRange)

        return result
    }

    private func buildSeparator(gutterDigits: Int) -> NSAttributedString {
        NSMutableAttributedString(string: " ··· \n", attributes: [
            .font: Self.font,
            .foregroundColor: NSColor(DiffColors.separatorFg(colorScheme)),
            .diffLineBackground: NSColor(DiffColors.separatorBg(colorScheme)),
        ])
    }
}

private struct DiffContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - NSTextView Bridge

private extension NSAttributedString.Key {
    /// Full-width line background color (drawn edge-to-edge by DiffNSTextView).
    static let diffLineBackground = NSAttributedString.Key("diffLineBackground")
    /// Per-character gutter background (drawn over the line background).
    static let diffGutterBackground = NSAttributedString.Key("diffGutterBackground")
}

/// NSTextView subclass that draws full-width line backgrounds
/// using custom attributes, before the standard text drawing pass.
private final class DiffNSTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        drawLineBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    private func drawLineBackgrounds(in dirtyRect: NSRect) {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage,
              ts.length > 0 else { return }

        lm.ensureLayout(for: tc)
        let origin = textContainerOrigin
        let fullWidth = max(ceil(lm.usedRect(for: tc).width), bounds.width)
        guard fullWidth > 0 else { return }

        let fullRange = NSRange(location: 0, length: ts.length)

        // 1. Full-width line backgrounds
        ts.enumerateAttribute(.diffLineBackground, in: fullRange) { value, range, _ in
            guard let color = value as? NSColor, color.alphaComponent > 0 else { return }
            let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateLineFragments(forGlyphRange: gr) { lineRect, _, _, _, _ in
                let rect = CGRect(
                    x: origin.x, y: lineRect.origin.y + origin.y,
                    width: fullWidth, height: lineRect.size.height
                )
                guard rect.intersects(dirtyRect) else { return }
                color.setFill()
                rect.fill()
            }
        }

        // 2. Gutter backgrounds (per-character width, layered on top)
        ts.enumerateAttribute(.diffGutterBackground, in: fullRange) { value, range, _ in
            guard let color = value as? NSColor, color.alphaComponent > 0 else { return }
            let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: gr, in: tc)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard rect.intersects(dirtyRect) else { return }
            color.setFill()
            rect.fill()
        }
    }
}

/// Bridges DiffNSTextView into SwiftUI, sized to its text content.
private struct DiffTextRepresentable: NSViewRepresentable {
    let attributedString: NSAttributedString
    let minWidth: CGFloat

    func makeNSView(context: Context) -> DiffNSTextView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)

        let tc = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)

        let tv = DiffNSTextView(frame: .zero, textContainer: tc)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero

        return tv
    }

    func updateNSView(_ tv: DiffNSTextView, context: Context) {
        tv.textStorage?.setAttributedString(attributedString)
        tv.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiffNSTextView, context: Context) -> CGSize? {
        guard let lm = nsView.layoutManager, let tc = nsView.textContainer else { return nil }
        lm.ensureLayout(for: tc)
        let rect = lm.usedRect(for: tc)
        return CGSize(width: max(ceil(rect.width), minWidth), height: ceil(rect.height))
    }
}

// MARK: - Colors

private enum DiffColors {
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
        case (.add, .dark):     Color(.sRGB, red: 63/255, green: 185/255, blue: 80/255, opacity: 0.25)
        case (.add, .light):    Color(.sRGB, red: 214/255, green: 236/255, blue: 222/255)
        case (.del, .dark):     Color(.sRGB, red: 248/255, green: 81/255, blue: 73/255, opacity: 0.25)
        case (.del, .light):    Color(.sRGB, red: 236/255, green: 214/255, blue: 216/255)
        case (.context, .dark): Color.white.opacity(0.04)
        case (.context, .light): Color.black.opacity(0.04)
        default: .clear
        }
    }

    static func contentBg(_ type: DiffEngine.Line.LineType, _ scheme: ColorScheme) -> Color {
        switch (type, scheme) {
        case (.add, .dark):     Color(.sRGB, red: 63/255, green: 185/255, blue: 80/255, opacity: 0.15)
        case (.add, .light):    Color(.sRGB, red: 230/255, green: 243/255, blue: 235/255)
        case (.del, .dark):     Color(.sRGB, red: 248/255, green: 81/255, blue: 73/255, opacity: 0.15)
        case (.del, .light):    Color(.sRGB, red: 243/255, green: 230/255, blue: 231/255)
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
}

// MARK: - Diff Engine

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

// MARK: - Previews

private let sampleOld = """
func greet(name: String) {
    print("Hello, \\(name)!")
    print("Welcome.")
}
"""

private let sampleNew = """
func greet(name: String, greeting: String = "Hello") {
    print("\\(greeting), \\(name)!")
    print("Welcome to the app.")
    logger.info("Greeted \\(name)")
}
"""

#Preview("Edit diff") {
    NativeDiffView(filePath: "Sources/Greeter.swift", oldString: sampleOld, newString: sampleNew)
        .padding()
        .frame(width: 500)
}

#Preview("New file (all additions)") {
    NativeDiffView(
        filePath: "config.yaml",
        oldString: "",
        newString: "port: 8080\nhost: localhost\ndebug: true\nlog_level: info"
    )
    .padding()
    .frame(width: 400)
}

#Preview("Delete lines") {
    NativeDiffView(
        filePath: "cleanup.sh",
        oldString: "echo start\nrm -rf /tmp/cache\nrm -rf /tmp/logs\necho done",
        newString: "echo start\necho done"
    )
    .padding()
    .frame(width: 400)
}

#Preview("Dark mode") {
    VStack(spacing: 16) {
        NativeDiffView(filePath: "App.swift", oldString: sampleOld, newString: sampleNew)
        NativeDiffView(filePath: "new.txt", oldString: "", newString: "line 1\nline 2\nline 3")
    }
    .padding()
    .frame(width: 500)
    .preferredColorScheme(.dark)
}

#Preview("Light mode") {
    VStack(spacing: 16) {
        NativeDiffView(filePath: "App.swift", oldString: sampleOld, newString: sampleNew)
        NativeDiffView(filePath: "new.txt", oldString: "", newString: "line 1\nline 2\nline 3")
    }
    .padding()
    .frame(width: 500)
    .preferredColorScheme(.light)
}
