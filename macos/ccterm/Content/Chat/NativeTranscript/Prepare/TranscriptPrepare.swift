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

// MARK: - Theme Sendable conformance

/// `TranscriptTheme` / `MarkdownTheme` are immutable value types wrapping
/// `NSFont` / `NSColor`. Both font and color instances are thread-safe to
/// read. The `@unchecked` conformance lets us ship themes across `Task`
/// boundaries without boxing them through actor-isolated bridges.
extension TranscriptTheme: @unchecked Sendable {}
extension MarkdownTheme: @unchecked Sendable {}
