import CoreGraphics

/// Where a group of pictures goes when they share one row.
///
/// A port of Telegram's `GroupedLayout.measure` — the arrangement its macOS and
/// iOS clients have shown for grouped media since 2017 — kept faithful down to
/// its constants and its two quirks, both marked below. Ported rather than
/// invented because the interesting cases are the ones intuition gets wrong: two
/// panoramas, a portrait beside two squares, five pictures of unrelated shapes.
/// Telegram's answer to each has been looked at by a great many people.
///
/// **It is not a grid.** No cell size is fixed and nothing is cropped to a
/// square. Every picture keeps its own proportion and the algorithm chooses
/// *rows* — how many pictures each row holds, and how tall each row is — so that
/// the ragged right edge closes and the block ends up near a target height. Two
/// and three and four pictures get hand-written arrangements chosen by their
/// proportions; five and up get a search.
///
/// ## Pure geometry
///
/// No AppKit, no views, no images — sizes in, rectangles out. So the arrangement
/// is testable as arithmetic, and a row can answer `heightOfRow` by running the
/// same layout it will later draw, from the same numbers, with no view built.
public struct MosaicLayout {

    /// Which of a tile's corners are on the outside of the block.
    ///
    /// The rounding rule Telegram draws: the group as a whole is a rounded
    /// rectangle, so a corner is round only where it is nobody's neighbour. Every
    /// other corner takes a much smaller radius — not zero, which reads as a
    /// crack between two pictures rather than as a seam.
    public struct Corners: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let topLeft = Corners(rawValue: 1 << 0)
        public static let topRight = Corners(rawValue: 1 << 1)
        public static let bottomLeft = Corners(rawValue: 1 << 2)
        public static let bottomRight = Corners(rawValue: 1 << 3)

        public static let all: Corners = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    /// One picture's place. `frame` is in the block's own space, top-left origin,
    /// y growing downward — `MeasuredBlock`'s convention, and the one a flipped
    /// `NSView` draws in.
    public struct Tile: Sendable {
        public let frame: CGRect
        public let outerCorners: Corners
    }

    public let tiles: [Tile]

    /// What the tiles add up to. Never wider than the `maxSize` handed in; the
    /// height is whatever the chosen arrangement came to, which is the number a
    /// row reports.
    public let size: CGSize

    // MARK: - Telegram's constants

    /// Between two pictures, horizontally and vertically alike.
    public static let spacing: CGFloat = 4

    /// No row may be shorter than this, and an arrangement that would go under it
    /// is penalised rather than forbidden — a picture narrower than a thumbnail
    /// is worse than a block that misses its target height.
    private static let minWidth: CGFloat = 70

    /// A picture is "wide" past this, "tall" under `narrowRatio`, and square-ish
    /// between. The three letters make the proportion string the hand-written
    /// arrangements switch on.
    private static let wideRatio: CGFloat = 1.2
    private static let narrowRatio: CGFloat = 0.8

    /// Past this, no hand-written arrangement is trusted and the search runs even
    /// for two or three pictures: a 3:1 panorama laid out by the two-picture rule
    /// would drag the whole row down to a sliver.
    private static let forceSearchRatio: CGFloat = 2.0

    /// How far a picture may be squeezed toward square before the search stops
    /// respecting its real proportion. Telegram's numbers: 2:3 and 17:10.
    private static let minCroppedRatio: CGFloat = 0.66667
    private static let maxCroppedRatio: CGFloat = 1.7

    /// The most rows a line-split may contain, and the most pictures in a row.
    private static let maxPerLine = 3
    private static let maxPerLineWhenTall = 4

    // MARK: -

    /// Lays `imageSizes` out inside `maxSize`.
    ///
    /// `maxSize.width` is a hard ceiling — the block is exactly this wide once
    /// there is more than one picture. `maxSize.height` is a *target*: the search
    /// aims at `height / 3 * 4` and settles for what the proportions allow, so a
    /// row of panoramas comes out short and a stack of portraits comes out tall.
    ///
    /// `scale` floors every rectangle onto the pixel grid, as Telegram does with
    /// the backing scale. Independent flooring can leave a half-point of daylight
    /// between two tiles; that is the trade Telegram takes, and taking it here
    /// too is what keeps a picture's own edge from being resampled.
    public init(
        imageSizes: [CGSize], maxSize: CGSize, spacing: CGFloat = MosaicLayout.spacing,
        scale: CGFloat = 2
    ) {
        let ratios = imageSizes.map { $0.height > 0 ? $0.width / $0.height : 1 }

        guard !ratios.isEmpty else {
            self.tiles = []
            self.size = .zero
            return
        }

        var frames: [CGRect]
        var corners: [Corners]

        if ratios.count == 1 {
            // Telegram hands a lone picture straight through at its natural size
            // and lets the caller fit it, because in a chat the caller has a
            // bubble to fit it to. Here the column is the fit, so it happens now.
            let ratio = ratios[0]
            let fitted =
                ratio >= maxSize.width / maxSize.height
                ? CGSize(width: maxSize.width, height: maxSize.width / ratio)
                : CGSize(width: maxSize.height * ratio, height: maxSize.height)
            frames = [CGRect(origin: .zero, size: fitted)]
            corners = [.all]
        } else {
            var proportions = ""
            // Telegram seeds this at 1.0 before summing, so the "average" is
            // pulled toward square by one imaginary square picture. Kept: it
            // feeds three thresholds, and correcting it here would silently
            // re-arrange groups that have looked one way for years.
            var averageRatio: CGFloat = 1.0
            var forceSearch = false

            for ratio in ratios {
                if ratio > Self.wideRatio {
                    proportions += "w"
                } else if ratio < Self.narrowRatio {
                    proportions += "n"
                } else {
                    proportions += "q"
                }
                averageRatio += ratio
                if ratio > Self.forceSearchRatio { forceSearch = true }
            }
            averageRatio /= CGFloat(ratios.count)

            let arranged: ([CGRect], [Corners])? =
                forceSearch
                ? nil
                : Self.handArranged(
                    ratios: ratios, proportions: proportions, averageRatio: averageRatio,
                    maxSize: maxSize, spacing: spacing)

            if let arranged {
                (frames, corners) = arranged
            } else {
                (frames, corners) = Self.searched(
                    ratios: ratios, averageRatio: averageRatio, maxSize: maxSize, spacing: spacing)
            }
        }

        let floored = frames.map { frame in
            CGRect(
                x: Self.floorToPixels(frame.minX, scale), y: Self.floorToPixels(frame.minY, scale),
                width: Self.floorToPixels(frame.width, scale),
                height: Self.floorToPixels(frame.height, scale))
        }

        self.tiles = zip(floored, corners).map { Tile(frame: $0, outerCorners: $1) }
        self.size = CGSize(
            width: Self.floorToPixels(floored.map(\.maxX).max() ?? 0, scale),
            height: Self.floorToPixels(floored.map(\.maxY).max() ?? 0, scale))
    }

    private static func floorToPixels(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded(.down) / scale
    }

    // MARK: - Two, three and four

    /// The arrangements Telegram writes out by hand, selected by the proportion
    /// string. `nil` for any count they do not cover, which sends the group to
    /// the search.
    private static func handArranged(
        ratios: [CGFloat], proportions: String, averageRatio: CGFloat, maxSize: CGSize,
        spacing: CGFloat
    ) -> ([CGRect], [Corners])? {
        let maxAspectRatio = maxSize.width / maxSize.height

        switch ratios.count {
        case 2:
            // Two panoramas of nearly the same shape: stacked, full width. Side
            // by side they would each be half a panorama, which is a letterbox.
            if proportions == "ww" && averageRatio > 1.4 * maxAspectRatio
                && ratios[1] - ratios[0] < 0.2
            {
                let width = maxSize.width
                let height = min(
                    width / ratios[0], min(width / ratios[1], (maxSize.height - spacing) / 2))
                return (
                    [
                        CGRect(x: 0, y: 0, width: width, height: height),
                        CGRect(x: 0, y: height + spacing, width: width, height: height),
                    ],
                    [[.topLeft, .topRight], [.bottomLeft, .bottomRight]]
                )
            }
            // Two of a kind: equal halves.
            if proportions == "ww" || proportions == "qq" {
                let width = (maxSize.width - spacing) / 2
                let height = min(width / ratios[0], min(width / ratios[1], maxSize.height))
                return (
                    [
                        CGRect(x: 0, y: 0, width: width, height: height),
                        CGRect(x: width + spacing, y: 0, width: width, height: height),
                    ],
                    [[.topLeft, .bottomLeft], [.topRight, .bottomRight]]
                )
            }
            // Mismatched: split the width so both come out the same height.
            let firstWidth =
                (maxSize.width - spacing) / ratios[1] / (1 / ratios[0] + 1 / ratios[1])
            let secondWidth = maxSize.width - firstWidth - spacing
            let height = min(
                maxSize.height, min(firstWidth / ratios[0], secondWidth / ratios[1]))
            return (
                [
                    CGRect(x: 0, y: 0, width: firstWidth, height: height),
                    CGRect(x: firstWidth + spacing, y: 0, width: secondWidth, height: height),
                ],
                [[.topLeft, .bottomLeft], [.topRight, .bottomRight]]
            )

        case 3:
            // Leading portrait: it takes the full height on the left, the other
            // two stack beside it.
            if proportions.hasPrefix("n") {
                let firstHeight = maxSize.height
                let thirdHeight = min(
                    (maxSize.height - spacing) * 0.5,
                    (ratios[1] * (maxSize.width - spacing) / (ratios[2] + ratios[1])).rounded())
                let secondHeight = maxSize.height - thirdHeight - spacing
                let rightWidth = max(
                    minWidth,
                    min(
                        (maxSize.width - spacing) * 0.5,
                        min(thirdHeight * ratios[2], secondHeight * ratios[1]).rounded()))
                let leftWidth = min(
                    firstHeight * ratios[0], maxSize.width - spacing - rightWidth
                ).rounded()
                return (
                    [
                        CGRect(x: 0, y: 0, width: leftWidth, height: firstHeight),
                        CGRect(
                            x: leftWidth + spacing, y: 0, width: rightWidth, height: secondHeight),
                        CGRect(
                            x: leftWidth + spacing, y: secondHeight + spacing, width: rightWidth,
                            height: thirdHeight),
                    ],
                    [[.topLeft, .bottomLeft], [.topRight], [.bottomRight]]
                )
            }
            // Otherwise a wide one on top, two under it.
            var width = maxSize.width
            let firstHeight = min(width / ratios[0], (maxSize.height - spacing) * 0.66).rounded(
                .down)
            width = (maxSize.width - spacing) / 2
            let secondHeight = min(
                maxSize.height - firstHeight - spacing,
                min(width / ratios[1], width / ratios[2]).rounded())
            return (
                [
                    CGRect(x: 0, y: 0, width: maxSize.width, height: firstHeight),
                    CGRect(x: 0, y: firstHeight + spacing, width: width, height: secondHeight),
                    CGRect(
                        x: width + spacing, y: firstHeight + spacing, width: width,
                        height: secondHeight),
                ],
                [[.topLeft, .topRight], [.bottomLeft], [.bottomRight]]
            )

        case 4:
            // A wide leader over a row of three, sized so the three fill the width.
            if proportions.hasPrefix("w") {
                let w = maxSize.width
                let h0 = min(w / ratios[0], (maxSize.height - spacing) * 0.66)

                var h = (maxSize.width - 2 * spacing) / (ratios[1] + ratios[2] + ratios[3])
                let w0 = max((maxSize.width - 2 * spacing) * 0.33, h * ratios[1])
                var w2 = max((maxSize.width - 2 * spacing) * 0.33, h * ratios[3])
                var w1 = w - w0 - w2 - 2 * spacing
                if w1 < minWidth {
                    w2 -= minWidth - w1
                    w1 = minWidth
                }
                h = min(maxSize.height - h0 - spacing, h)
                return (
                    [
                        CGRect(x: 0, y: 0, width: w, height: h0),
                        CGRect(x: 0, y: h0 + spacing, width: w0, height: h),
                        CGRect(x: w0 + spacing, y: h0 + spacing, width: w1, height: h),
                        CGRect(x: w0 + w1 + 2 * spacing, y: h0 + spacing, width: w2, height: h),
                    ],
                    [[.topLeft, .topRight], [.bottomLeft], [], [.bottomRight]]
                )
            }
            // A tall leader on the left, three stacked beside it.
            let h = maxSize.height
            let w0 = min(h * ratios[0], (maxSize.width - spacing) * 0.6)
            var w = (maxSize.height - 2 * spacing) / (1 / ratios[1] + 1 / ratios[2] + 1 / ratios[3])
            let h0 = w / ratios[1]
            let h1 = w / ratios[2]
            let h2 = w / ratios[3]
            w = min(maxSize.width - w0 - spacing, w)
            return (
                [
                    CGRect(x: 0, y: 0, width: w0, height: h),
                    CGRect(x: w0 + spacing, y: 0, width: w, height: h0),
                    CGRect(x: w0 + spacing, y: h0 + spacing, width: w, height: h1),
                    CGRect(x: w0 + spacing, y: h0 + h1 + 2 * spacing, width: w, height: h2),
                ],
                [[.topLeft, .bottomLeft], [.topRight], [], [.bottomRight]]
            )

        default:
            return nil
        }
    }

    // MARK: - Five and up

    private struct Attempt {
        let lineCounts: [Int]
        let heights: [CGFloat]
    }

    /// Every way of cutting the pictures into one to four rows, scored, and the
    /// best one laid out.
    ///
    /// The rows keep the pictures in order — this chooses *where the breaks go*,
    /// not which picture goes where. Within a row, one shared height and each
    /// picture's own proportion give the widths, so the row fills the column
    /// exactly by construction.
    private static func searched(
        ratios: [CGFloat], averageRatio: CGFloat, maxSize: CGSize, spacing: CGFloat
    ) -> ([CGRect], [Corners]) {
        let count = ratios.count

        // Squeezed toward square first, and in the direction the group as a whole
        // leans: among wide pictures a tall one is stretched up to square rather
        // than left as a sliver in a row sized for panoramas.
        let cropped: [CGFloat] = ratios.map { ratio in
            let toward = averageRatio > 1.1 ? max(1, ratio) : min(1, ratio)
            return max(minCroppedRatio, min(maxCroppedRatio, toward))
        }

        /// The height at which this many pictures, at these proportions, exactly
        /// fill the column.
        func multiHeight(_ slice: ArraySlice<CGFloat>) -> CGFloat {
            let sum = slice.reduce(0, +)
            guard sum > 0 else { return 0 }
            return (maxSize.width - (CGFloat(slice.count) - 1) * spacing) / sum
        }

        var attempts: [Attempt] = [
            Attempt(lineCounts: [count], heights: [multiHeight(cropped[0...])])
        ]

        for first in 1..<count {
            let second = count - first
            if first > maxPerLine || second > maxPerLine { continue }
            attempts.append(
                Attempt(
                    lineCounts: [first, second],
                    heights: [multiHeight(cropped[0..<first]), multiHeight(cropped[first...])]))
        }

        if count > 1 {
            for first in 1..<(count - 1) {
                for second in 1..<(count - first) {
                    let third = count - first - second
                    // Telegram widens the middle row to four when the group leans
                    // tall — portraits are narrow, so a row of three leaves the
                    // column short.
                    let secondLimit = averageRatio < 0.85 ? maxPerLineWhenTall : maxPerLine
                    if first > maxPerLine || second > secondLimit || third > maxPerLine {
                        continue
                    }
                    attempts.append(
                        Attempt(
                            lineCounts: [first, second, third],
                            heights: [
                                multiHeight(cropped[0..<first]),
                                multiHeight(cropped[first..<(first + second)]),
                                multiHeight(cropped[(first + second)...]),
                            ]))
                }
            }
        }

        if count > 2 {
            for first in 1..<(count - 2) {
                for second in 1..<(count - first) {
                    for third in 1..<(count - first - second) {
                        let fourth = count - first - second - third
                        if first > maxPerLine || second > maxPerLine || third > maxPerLine
                            || fourth > maxPerLine
                        {
                            continue
                        }
                        attempts.append(
                            Attempt(
                                lineCounts: [first, second, third, fourth],
                                heights: [
                                    multiHeight(cropped[0..<first]),
                                    multiHeight(cropped[first..<(first + second)]),
                                    multiHeight(cropped[(first + second)..<(first + second + third)]),
                                    multiHeight(cropped[(first + second + third)...]),
                                ]))
                    }
                }
            }
        }

        // A third taller than the space offered, which is what makes a group of
        // pictures read as a block of pictures rather than as a strip.
        let targetHeight = maxSize.height / 3 * 4
        var optimal: Attempt?
        var optimalDiff: CGFloat = 0

        for attempt in attempts {
            var totalHeight = spacing * (CGFloat(attempt.heights.count) - 1)
            var minLineHeight = CGFloat.greatestFiniteMagnitude
            for lineHeight in attempt.heights {
                totalHeight += lineHeight
                minLineHeight = min(minLineHeight, lineHeight)
            }

            var diff = abs(totalHeight - targetHeight)

            // Two penalties, both multiplicative and both worth half again.
            // A row wider than the one under it reads top-heavy...
            let counts = attempt.lineCounts
            if counts.count > 1 {
                if counts[0] > counts[1] || (counts.count > 2 && counts[1] > counts[2])
                    || (counts.count > 3 && counts[2] > counts[3])
                {
                    diff *= 1.5
                }
            }
            // ...and a row under the minimum is a picture too small to see.
            if minLineHeight < minWidth { diff *= 1.5 }

            if optimal == nil || diff < optimalDiff {
                optimal = attempt
                optimalDiff = diff
            }
        }

        guard let optimal else { return ([], []) }

        var frames: [CGRect] = []
        var corners: [Corners] = []
        var index = 0
        var y: CGFloat = 0

        for (line, lineCount) in optimal.lineCounts.enumerated() {
            let lineHeight = optimal.heights[line]
            let isTop = line == 0
            let isBottom = line == optimal.lineCounts.count - 1
            var x: CGFloat = 0

            for column in 0..<lineCount {
                let isLeft = column == 0
                let isRight = column == lineCount - 1

                var tileCorners: Corners = []
                if isTop && isLeft { tileCorners.insert(.topLeft) }
                if isTop && isRight { tileCorners.insert(.topRight) }
                if isBottom && isLeft { tileCorners.insert(.bottomLeft) }
                if isBottom && isRight { tileCorners.insert(.bottomRight) }

                let width = cropped[index] * lineHeight
                frames.append(CGRect(x: x, y: y, width: width, height: lineHeight))
                corners.append(tileCorners)

                x += width + spacing
                index += 1
            }
            y += lineHeight + spacing
        }

        return (frames, corners)
    }
}
