import AppKit
import SwiftUI

/// Nonisolated prepare/layout machinery for transcript rows.
///
/// Pipeline:
///   1. `prepare*` — off-main. Parse Markdown, prebuild `PrebuiltSegment`s.
///      Output is a Sendable value (`AssistantPrepared` / `UserPrepared` /
///      `PlaceholderPrepared`).
///   2. `layout*` — off-main. Takes prepared + theme + width, returns
///      `*LayoutData` (Sendable). Calls into CoreText / `TranscriptTextLayout` /
///      `TranscriptTableLayout`, all of which are thread-safe.
///   3. Main thread: `Row.init(prepared:theme:)` + `row.applyLayout(_:)` adopt
///      the precomputed data in O(1) — no CoreText calls, no NSFontManager.
///
/// The functions are plain `static` on an `enum` (no actor). Callers schedule
/// them via `Task.detached` or any other off-main mechanism. Sendable
/// conformances on the prepared / layout structs are `@unchecked` because the
/// nested reference types (`NSAttributedString`, `CTLine`, `NSFont`,
/// `NSColor`, `MarkdownDocument` sub-trees) are documented thread-safe for
/// read access, and the structs themselves are treated as immutable snapshots
/// once produced.
nonisolated enum TranscriptPrepare {

    // MARK: - Prepare (source → prebuilt)

    /// Parse + prebuild for an assistant markdown row. Matches the work
    /// previously done synchronously inside `AssistantMarkdownRow.init`.
    nonisolated static func assistant(
        source: String,
        theme: TranscriptTheme,
        stable: AnyHashable
    ) -> AssistantPrepared {
        let doc = MarkdownDocument(parsing: source)
        let prebuilt = MarkdownRowPrebuilder.build(
            document: doc,
            theme: theme,
            codeTokens: [:])
        var hasher = Hasher()
        hasher.combine(source)
        hasher.combine(theme.markdown.fingerprint)
        return AssistantPrepared(
            source: source,
            parsedDocument: doc,
            prebuilt: prebuilt,
            stable: stable,
            contentHash: hasher.finalize(),
            hasHighlight: false)
    }

    /// Prepare metadata for a user bubble. The actual text layout is
    /// width-dependent and happens in ``layoutUser``.
    nonisolated static func user(
        text: String,
        theme: TranscriptTheme,
        stable: AnyHashable
    ) -> UserPrepared {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(theme.markdown.fingerprint)
        return UserPrepared(
            text: text,
            stable: stable,
            contentHash: hasher.finalize())
    }

    /// Prepare metadata for a placeholder row.
    nonisolated static func placeholder(
        label: String,
        theme: TranscriptTheme,
        stable: AnyHashable
    ) -> PlaceholderPrepared {
        var hasher = Hasher()
        hasher.combine(label)
        hasher.combine(theme.markdown.fingerprint)
        return PlaceholderPrepared(
            label: label,
            stable: stable,
            contentHash: hasher.finalize())
    }

    // MARK: - Layout (prebuilt → rendered segments for a given width)

    /// Lays out the prebuilt segments for a given width. Equivalent to the
    /// interior of `AssistantMarkdownRow.makeSize(width:)` but pure — returns
    /// a value instead of mutating row state. Table selection matrices are
    /// returned empty (sized); callers (`applyLayout`) merge in any existing
    /// selections.
    nonisolated static func layoutAssistant(
        prebuilt: [AssistantMarkdownRow.PrebuiltSegment],
        theme: TranscriptTheme,
        width: CGFloat
    ) -> AssistantLayoutData {
        let contentWidth = max(40, width - 2 * theme.rowHorizontalPadding)
        var segments: [AssistantMarkdownRow.RenderedSegment] = []
        var origins: [Int: CGPoint] = [:]
        var newTableSelections: [Int: [[NSRange]]] = [:]
        var headerRects: [(rect: CGRect, segmentIndex: Int, code: String)] = []
        var y: CGFloat = theme.rowVerticalPadding

        for (idx, prebuiltSeg) in prebuilt.enumerated() {
            y += prebuiltSeg.topPadding

            switch prebuiltSeg {
            case .attributed(let attr, let kind, _):
                let maxWidth: CGFloat
                let layoutOriginX: CGFloat
                let layoutOriginY: CGFloat
                switch kind {
                case .text, .heading:
                    maxWidth = contentWidth
                    layoutOriginX = theme.rowHorizontalPadding
                    layoutOriginY = y
                case .blockquote:
                    let barSpace = theme.markdown.blockquoteBarWidth + theme.markdown.blockquoteBarGap
                    maxWidth = max(40, contentWidth - barSpace)
                    layoutOriginX = theme.rowHorizontalPadding + barSpace
                    layoutOriginY = y
                case .codeBlock(let header):
                    maxWidth = max(40, contentWidth - 2 * theme.codeBlockHorizontalPadding)
                    layoutOriginX = theme.rowHorizontalPadding + theme.codeBlockHorizontalPadding
                    layoutOriginY = y + theme.codeBlockHeaderHeight + theme.codeBlockVerticalPadding
                    headerRects.append((
                        rect: CGRect(
                            x: theme.rowHorizontalPadding,
                            y: y,
                            width: contentWidth,
                            height: theme.codeBlockHeaderHeight),
                        segmentIndex: idx,
                        code: header.code))
                }
                let layout = TranscriptTextLayout.make(attributed: attr, maxWidth: maxWidth)
                segments.append(.attributed(
                    layout, kind: kind,
                    layoutOrigin: CGPoint(x: layoutOriginX, y: layoutOriginY)))
                origins[idx] = CGPoint(x: layoutOriginX, y: layoutOriginY)

                switch kind {
                case .codeBlock:
                    y += theme.codeBlockHeaderHeight
                        + layout.totalHeight
                        + 2 * theme.codeBlockVerticalPadding
                default:
                    y += layout.totalHeight
                }

            case .list(let contents, _):
                let listLayout = TranscriptListLayout.make(
                    contents: contents,
                    theme: theme,
                    maxWidth: contentWidth)
                let origin = CGPoint(x: theme.rowHorizontalPadding, y: y)
                segments.append(.list(listLayout, origin: origin))
                y += listLayout.totalHeight

            case .table(let contents, _):
                let tableLayout = TranscriptTableLayout.make(
                    contents: contents,
                    theme: theme,
                    maxWidth: contentWidth)
                segments.append(.table(
                    tableLayout,
                    origin: CGPoint(x: theme.rowHorizontalPadding, y: y)))
                let rowCount = tableLayout.rowHeights.count
                let colCount = tableLayout.columnWidths.count
                let matrix = [[NSRange]](
                    repeating: [NSRange](
                        repeating: NSRange(location: NSNotFound, length: 0),
                        count: colCount),
                    count: rowCount)
                newTableSelections[idx] = matrix
                y += tableLayout.totalHeight

            case .thematicBreak:
                segments.append(.thematicBreak(y: y))
                y += 1
            }
        }

        y += theme.rowVerticalPadding

        return AssistantLayoutData(
            rendered: segments,
            attributedOrigins: origins,
            codeBlockHeaderRects: headerRects,
            tableSelectionsSkeleton: newTableSelections,
            cachedHeight: y,
            cachedWidth: width)
    }

    /// User bubble 排版的 CT 阶段产物。只依赖 `(text, width, theme)`，
    /// 与 `isExpanded` 无关，可在 toggle 时复用。
    struct UserBubbleCT: @unchecked Sendable {
        let textLayout: TranscriptTextLayout
        let bubbleWidth: CGFloat
        let bubbleX: CGFloat
    }

    /// CT 阶段：跑 CoreText 排版，算出 textLayout / bubbleWidth / bubbleX。
    /// 重活集中在 `TranscriptTextLayout.make`。
    nonisolated static func userBubbleCT(
        text: String,
        theme: TranscriptTheme,
        width: CGFloat
    ) -> UserBubbleCT {
        let maxBubbleWidth = max(120, min(
            theme.userBubbleMaxWidth,
            width - theme.bubbleMinLeftGutter - theme.bubbleRightInset))
        let contentMaxWidth = max(40, maxBubbleWidth - 2 * theme.bubbleHorizontalPadding)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.markdown.bodyFont,
            .foregroundColor: theme.markdown.primaryColor,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textLayout = TranscriptTextLayout.make(
            attributed: attr,
            maxWidth: contentMaxWidth)

        let bubbleWidth = min(
            maxBubbleWidth,
            textLayout.measuredWidth + 2 * theme.bubbleHorizontalPadding)
        let bubbleX = width - theme.bubbleRightInset - bubbleWidth

        return UserBubbleCT(textLayout: textLayout, bubbleWidth: bubbleWidth, bubbleX: bubbleX)
    }

    /// 几何阶段：基于已有 CT 结果拼装 bubbleRect / textOrigin / cachedHeight。
    /// 唯一依赖 `isExpanded` 的部分——toggle 时只需要重跑这一阶段。
    nonisolated static func userBubbleGeometry(
        ct: UserBubbleCT,
        theme: TranscriptTheme,
        width: CGFloat,
        isExpanded: Bool
    ) -> UserLayoutData {
        let canCollapse = ct.textLayout.lines.count
            >= theme.userBubbleCollapseThreshold + theme.userBubbleMinHiddenLines
        let shouldCollapse = canCollapse && !isExpanded
        let bubbleHeight: CGFloat
        if shouldCollapse,
           ct.textLayout.lineRects.indices.contains(theme.userBubbleCollapseThreshold - 1) {
            let visibleHeight = ct.textLayout.lineRects[theme.userBubbleCollapseThreshold - 1].maxY
            bubbleHeight = visibleHeight + 2 * theme.bubbleVerticalPadding
        } else {
            bubbleHeight = ct.textLayout.totalHeight + 2 * theme.bubbleVerticalPadding
        }
        let bubbleRect = CGRect(
            x: ct.bubbleX,
            y: theme.rowVerticalPadding,
            width: ct.bubbleWidth,
            height: bubbleHeight)
        let textOriginInRow = CGPoint(
            x: bubbleRect.minX + theme.bubbleHorizontalPadding,
            y: bubbleRect.minY + theme.bubbleVerticalPadding)
        let cachedHeight = bubbleHeight + 2 * theme.rowVerticalPadding

        return UserLayoutData(
            textLayout: ct.textLayout,
            bubbleRect: bubbleRect,
            textOriginInRow: textOriginInRow,
            bubbleWidth: ct.bubbleWidth,
            bubbleX: ct.bubbleX,
            cachedHeight: cachedHeight,
            cachedWidth: width,
            lastLayoutExpanded: isExpanded)
    }

    /// 一站式：CT + 几何，prepare 阶段和 row 的 width-changed 路径都走这里。
    nonisolated static func layoutUser(
        text: String,
        theme: TranscriptTheme,
        width: CGFloat,
        isExpanded: Bool
    ) -> UserLayoutData {
        let ct = userBubbleCT(text: text, theme: theme, width: width)
        return userBubbleGeometry(ct: ct, theme: theme, width: width, isExpanded: isExpanded)
    }

    /// Lays out a placeholder row. Width-independent typesetting, fixed height.
    nonisolated static func layoutPlaceholder(
        label: String,
        theme: TranscriptTheme
    ) -> PlaceholderLayoutData {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.placeholderTextFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return PlaceholderLayoutData(
            labelLine: line,
            labelAscent: ascent,
            labelDescent: descent,
            cachedHeight: theme.placeholderHeight + 2 * theme.rowVerticalPadding)
    }

    // MARK: - Diff (Edit / Write tool block)

    /// Parse diff hunks from `oldString` / `newString`, derive language from
    /// the filename. Width-independent — no CT work at this stage.
    nonisolated static func diff(
        filePath: String,
        oldString: String,
        newString: String,
        suppressInsertionStyle: Bool,
        theme: TranscriptTheme,
        stable: AnyHashable
    ) -> DiffPrepared {
        let hunks = DiffEngine.computeHunks(old: oldString, new: newString)
        let language = LanguageDetection.language(for: filePath)
        var hasher = Hasher()
        hasher.combine(filePath)
        hasher.combine(oldString)
        hasher.combine(newString)
        hasher.combine(suppressInsertionStyle)
        hasher.combine(theme.markdown.fingerprint)
        return DiffPrepared(
            filePath: filePath,
            hunks: hunks,
            language: language,
            suppressInsertionStyle: suppressInsertionStyle,
            stable: stable,
            contentHash: hasher.finalize(),
            lineHighlights: [:],
            hasHighlight: false)
    }

    /// Lay out diff body at a specific width. Runs CT typesetting per content
    /// line (wrapped). Highlight tokens (if provided via `prepared.lineHighlights`)
    /// are folded into the per-line attributed string so wrapping + colors
    /// land in one pass.
    nonisolated static func layoutDiff(
        prepared: DiffPrepared,
        theme: TranscriptTheme,
        width: CGFloat
    ) -> DiffLayoutData {
        let rowHPad = theme.rowHorizontalPadding
        let rowVPad = theme.rowVerticalPadding
        let containerWidth = max(60, width - 2 * rowHPad)

        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let monoGlyphW = measureMonospaceGlyphWidth(font: monoFont)
        let monoLineHeight = ceil(monoFont.ascender - monoFont.descender + 2)

        // Column widths (all in glyph-multiples of the monospace font).
        let maxLineNo = prepared.hunks.flatMap(\.lines).compactMap(\.lineNo).max() ?? 0
        let gutterDigits = max(2, String(maxLineNo).count)
        let lineNoColumnWidth = CGFloat(gutterDigits + 2) * monoGlyphW  // " 42 "
        let signColumnWidth = 3 * monoGlyphW                             // " + "
        let contentTrailing: CGFloat = 8

        // Column X positions (row-local).
        let containerX = rowHPad
        let lineNoColumnX = containerX
        let signColumnX = lineNoColumnX + lineNoColumnWidth
        let contentColumnX = signColumnX + signColumnWidth
        let contentMaxWidth = max(
            40,
            (containerX + containerWidth) - contentColumnX - contentTrailing)

        // Layout walk: rowVPad (top) | [header | headerGap | body | innerBottom] | rowVPad (bottom)
        var y: CGFloat = rowVPad
        let containerY = y

        // Header: basename + optional language tag.
        let basename = (prepared.filePath as NSString).lastPathComponent
        let headerText = (prepared.language.map { "\(basename) · \($0)" }) ?? basename
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let headerAttr = NSAttributedString(
            string: headerText,
            attributes: [
                .font: headerFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        let headerLine = CTLineCreateWithAttributedString(headerAttr)
        var hAsc: CGFloat = 0, hDesc: CGFloat = 0, hLead: CGFloat = 0
        let headerWidth = CGFloat(CTLineGetTypographicBounds(
            headerLine, &hAsc, &hDesc, &hLead))
        let headerBarHeight: CGFloat = 22
        let headerRect = CGRect(
            x: containerX, y: y,
            width: containerWidth, height: headerBarHeight)
        y += headerBarHeight

        let headerBodyGap: CGFloat = 2
        y += headerBodyGap

        // Body entries: lines + hunk separators.
        var entries: [DiffEntryLayout] = []
        for (hIdx, hunk) in prepared.hunks.enumerated() {
            if hIdx > 0 {
                entries.append(.separator(DiffSeparatorEntry(
                    y: y, height: monoLineHeight)))
                y += monoLineHeight
            }
            for line in hunk.lines {
                let effType: DiffEngine.Line.LineType =
                    (prepared.suppressInsertionStyle && line.type == .add)
                        ? .context : line.type

                let rawContent = line.content.isEmpty ? " " : line.content
                let contentAttr = buildDiffContentAttr(
                    content: rawContent,
                    tokens: prepared.lineHighlights[line.content],
                    font: monoFont)
                let contentLayout = TranscriptTextLayout.make(
                    attributed: contentAttr,
                    maxWidth: contentMaxWidth)

                let lineH = max(monoLineHeight, contentLayout.totalHeight)
                entries.append(.line(DiffLineEntry(
                    type: effType,
                    content: line.content,
                    lineNoText: line.lineNo.map(String.init) ?? "",
                    y: y,
                    height: lineH,
                    contentLayout: contentLayout)))
                y += lineH
            }
        }

        let innerBottomPad: CGFloat = 4
        y += innerBottomPad
        let containerHeight = y - containerY
        let containerRect = CGRect(
            x: containerX, y: containerY,
            width: containerWidth, height: containerHeight)

        y += rowVPad
        let cachedHeight = y

        return DiffLayoutData(
            cachedWidth: width,
            cachedHeight: cachedHeight,
            containerRect: containerRect,
            headerRect: headerRect,
            headerLine: headerLine,
            headerAscent: hAsc,
            headerDescent: hDesc,
            headerWidth: headerWidth,
            entries: entries,
            lineNoColumnX: lineNoColumnX,
            lineNoColumnWidth: lineNoColumnWidth,
            signColumnX: signColumnX,
            signColumnWidth: signColumnWidth,
            contentColumnX: contentColumnX,
            monoFont: monoFont,
            monoGlyphWidth: monoGlyphW,
            monoLineHeight: monoLineHeight,
            gutterDigits: gutterDigits)
    }

    /// Build per-line content attributed string. With highlight tokens →
    /// colored (one attributed run per token). Without → single plain run.
    /// Dynamic NSColors let appearance switches skip layout rebuild.
    nonisolated private static func buildDiffContentAttr(
        content: String,
        tokens: [SyntaxToken]?,
        font: NSFont
    ) -> NSAttributedString {
        if let tokens, !tokens.isEmpty {
            let result = NSMutableAttributedString()
            for token in tokens {
                let scope = token.scope
                let color = NSColor(name: nil) { appearance in
                    let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                    let scheme: ColorScheme = match == .darkAqua ? .dark : .light
                    return NSColor(SyntaxTheme.color(for: scope, scheme: scheme))
                }
                result.append(NSAttributedString(
                    string: token.text,
                    attributes: [.font: font, .foregroundColor: color]))
            }
            return result
        }
        return NSAttributedString(
            string: content,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ])
    }

    /// Measure the width of a single monospace glyph. Diff columns (line
    /// numbers, signs) are sized in glyph-multiples so alignment stays
    /// pixel-perfect regardless of font metrics.
    nonisolated private static func measureMonospaceGlyphWidth(font: NSFont) -> CGFloat {
        let attr = NSAttributedString(string: "M", attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

// MARK: - Prepared values (source-level metadata + width-independent prebuilt)

struct AssistantPrepared: @unchecked Sendable {
    let source: String
    let parsedDocument: MarkdownDocument
    let prebuilt: [AssistantMarkdownRow.PrebuiltSegment]
    let stable: AnyHashable
    let contentHash: Int
    /// `true` once syntax highlight tokens have been folded into `prebuilt`.
    /// Used by `TranscriptPrepareCache` to distinguish plain vs. colored
    /// cached entries, and by `applyHighlightTokens` to skip items that
    /// already carry tokens (typically cache hits on re-entry).
    let hasHighlight: Bool
}

struct UserPrepared: @unchecked Sendable {
    let text: String
    let stable: AnyHashable
    let contentHash: Int
}

struct PlaceholderPrepared: @unchecked Sendable {
    let label: String
    let stable: AnyHashable
    let contentHash: Int
}

struct DiffPrepared: @unchecked Sendable {
    let filePath: String
    let hunks: [DiffEngine.Hunk]
    let language: String?
    let suppressInsertionStyle: Bool
    let stable: AnyHashable
    let contentHash: Int
    /// Line content → syntax highlight tokens. Filled by Phase 2 highlight
    /// writeback (see step 5 of the plan). Empty → plain monospace rendering.
    let lineHighlights: [String: [SyntaxToken]]
    /// `true` once highlight tokens have been folded into `lineHighlights`.
    /// Used by `applyHighlightTokens` to skip items that already carry them
    /// (typically cache hits on re-entry).
    let hasHighlight: Bool
}

// MARK: - Layout data (rendered segments at a specific width)

struct AssistantLayoutData: @unchecked Sendable {
    let rendered: [AssistantMarkdownRow.RenderedSegment]
    let attributedOrigins: [Int: CGPoint]
    let codeBlockHeaderRects: [(rect: CGRect, segmentIndex: Int, code: String)]
    let tableSelectionsSkeleton: [Int: [[NSRange]]]
    let cachedHeight: CGFloat
    let cachedWidth: CGFloat
}

struct UserLayoutData: @unchecked Sendable {
    let textLayout: TranscriptTextLayout
    let bubbleRect: CGRect
    let textOriginInRow: CGPoint
    let bubbleWidth: CGFloat
    let bubbleX: CGFloat
    let cachedHeight: CGFloat
    let cachedWidth: CGFloat
    let lastLayoutExpanded: Bool
}

struct PlaceholderLayoutData: @unchecked Sendable {
    let labelLine: CTLine
    let labelAscent: CGFloat
    let labelDescent: CGFloat
    let cachedHeight: CGFloat
}

struct DiffLayoutData: @unchecked Sendable {
    let cachedWidth: CGFloat
    let cachedHeight: CGFloat

    /// Outer rounded container (the whole diff panel).
    let containerRect: CGRect

    /// Header bar (file basename + language tag).
    let headerRect: CGRect
    let headerLine: CTLine
    let headerAscent: CGFloat
    let headerDescent: CGFloat
    let headerWidth: CGFloat

    /// Body entries (lines + hunk separators) in visual top-to-bottom order.
    let entries: [DiffEntryLayout]

    /// Column layout (shared across lines, monospace-aligned).
    let lineNoColumnX: CGFloat
    let lineNoColumnWidth: CGFloat
    let signColumnX: CGFloat
    let signColumnWidth: CGFloat
    let contentColumnX: CGFloat

    /// Monospace font + metrics reused for line numbers / signs.
    let monoFont: NSFont
    let monoGlyphWidth: CGFloat
    let monoLineHeight: CGFloat

    /// Digit count of the widest line number (for right-aligning numerics).
    let gutterDigits: Int
}

/// One visual element inside a diff body: a line or a hunk separator.
enum DiffEntryLayout: @unchecked Sendable {
    case line(DiffLineEntry)
    case separator(DiffSeparatorEntry)
}

struct DiffLineEntry: @unchecked Sendable {
    /// Effective line type after `suppressInsertionStyle` is applied (Write
    /// maps .add → .context so new files render without noise).
    let type: DiffEngine.Line.LineType
    /// Raw content string — used as the key for `lineHighlights` writeback.
    let content: String
    /// Pre-formatted line number ("" for no number).
    let lineNoText: String
    /// Top Y of this line's full-width bg rect.
    let y: CGFloat
    /// Total height occupied by this line (≥ mono line height; larger when
    /// the content wraps to multiple visual lines).
    let height: CGFloat
    /// Wrapped content layout (CTTypesetter).
    let contentLayout: TranscriptTextLayout
}

struct DiffSeparatorEntry: @unchecked Sendable {
    let y: CGFloat
    let height: CGFloat
}

// MARK: - Heterogeneous item bundle

/// A prepared row-worth of data: one enum case per concrete row type.
/// Produced by `TranscriptRowBuilder.prepareAll` off-main; consumed on main
/// by `TranscriptController.row(from:theme:)` which wraps it into a
/// `TranscriptRow` instance.
enum TranscriptPreparedItem: @unchecked Sendable {
    case assistant(AssistantPrepared, AssistantLayoutData)
    case user(UserPrepared, UserLayoutData, isExpanded: Bool)
    case placeholder(PlaceholderPrepared, PlaceholderLayoutData)
    case diff(DiffPrepared, DiffLayoutData)
}

// MARK: - Theme Sendable conformance

/// `TranscriptTheme` / `MarkdownTheme` are immutable value types wrapping
/// `NSFont` / `NSColor`. Both font and color instances are thread-safe to
/// read. The `@unchecked` conformance lets us ship themes across `Task`
/// boundaries without boxing them through actor-isolated bridges.
extension TranscriptTheme: @unchecked Sendable {}
extension MarkdownTheme: @unchecked Sendable {}
