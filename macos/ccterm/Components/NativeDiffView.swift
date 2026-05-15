import SwiftUI

/// Native SwiftUI unified diff view with syntax highlighting via highlight.js (JSCore).
/// Uses NSTextView (TextKit 1) for full-width line backgrounds without padding hacks.
struct NativeDiffView: View {
    let filePath: String
    let oldString: String
    let newString: String
    var maxHeight: CGFloat? = nil
    /// When true, `.add` lines render like `.context` — no `+` sign, no green
    /// background. Line numbers and syntax highlighting are kept. Use for
    /// "new file" views that want a gutter + code without the diff noise.
    var suppressInsertionStyle: Bool = false

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
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

        let effectiveType: DiffEngine.Line.LineType =
            (suppressInsertionStyle && line.type == .add) ? .context : line.type

        let sign: String
        let signColor: NSColor
        switch effectiveType {
        case .add:     sign = "+"; signColor = NSColor(DiffColors.signAdd(colorScheme))
        case .del:     sign = "-"; signColor = NSColor(DiffColors.signDel(colorScheme))
        case .context: sign = " "; signColor = .clear
        }

        let gutterBg = NSColor(DiffColors.gutterBg(effectiveType, colorScheme))
        let contentBg = NSColor(DiffColors.contentBg(effectiveType, colorScheme))

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

#Preview("New file — suppressed insertion style") {
    NativeDiffView(
        filePath: "Sources/Greeter.swift",
        oldString: "",
        newString: sampleNew,
        suppressInsertionStyle: true
    )
    .padding()
    .frame(width: 500)
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
