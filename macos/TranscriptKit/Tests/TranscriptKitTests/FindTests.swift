import AppKit
import XCTest

@testable import TranscriptKit

/// Finding text, on both sides of the seam.
///
/// The block half is pure: a hit is a pair of indices in a tree's own space, and
/// what it must satisfy is that those indices name the characters a reader can
/// see — so every assertion here reads the hit back through `text(from:to:)` or
/// `rects(from:to:)` rather than against a number counted by hand.
///
/// The transcript half is mounted, because a find is a walk over rows the data
/// source answers, published across several turns, drawn into cells that recycle.
/// None of that exists until `NSTableView` lays out and starts asking.
@MainActor
final class FindTests: XCTestCase {

    // MARK: - A hit names characters

    private func block(_ source: String, width: CGFloat = 400) -> MeasuredBlock {
        MarkdownBlockBuilder.make(source).measure(width)
    }

    /// What every other assertion here rests on: the indices come back naming the
    /// query, so a wrong base anywhere in the composition shows up as the wrong
    /// substring rather than as a plausible number.
    func testAHitNamesTheCharactersItMatched() {
        let tree = block("The first paragraph.\n\nThe second paragraph mentions swift.")
        let hits = tree.ranges(of: "paragraph")

        XCTAssertEqual(hits.count, 2)
        for hit in hits {
            XCTAssertEqual(tree.text(from: hit.lowerBound, to: hit.upperBound), "paragraph")
        }
    }

    /// A hit late in a long document is the case that catches a drifting base: the
    /// stack joins its children's text with a newline it reserves no index for, so
    /// an implementation deriving hits from the joined string is off by one per
    /// boundary and only visibly wrong once several boundaries have gone by.
    func testAHitStaysAlignedDeepIntoADocument() throws {
        let paragraphs = (1...30).map { "Paragraph number \($0) with some ordinary words in it." }
        let tree = block(paragraphs.joined(separator: "\n\n") + "\n\nThe needle is here.")

        let hits = tree.ranges(of: "needle")
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(tree.text(from: hit.lowerBound, to: hit.upperBound), "needle")
    }

    func testAHitTurnsIntoRectanglesInsideTheBlock() throws {
        let tree = block("# A heading\n\nSome prose with a needle in it.")
        let hit = try XCTUnwrap(tree.ranges(of: "needle").first)

        let rects = tree.rects(from: hit.lowerBound, to: hit.upperBound)
        XCTAssertFalse(rects.isEmpty, "a hit with no geometry cannot be highlighted")
        for rect in rects {
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertTrue(
                CGRect(origin: .zero, size: tree.size).contains(rect),
                "\(rect) is outside the block")
        }
    }

    // MARK: - What is searched, and what is not

    /// Two paragraphs are two paragraphs. The premise is asserted alongside, so a
    /// build where neither word was found for some unrelated reason cannot pass.
    func testAMatchNeverSpansTwoBlocks() {
        let tree = block("A line that ends here.\n\nAnd there it starts again.")

        XCTAssertEqual(tree.ranges(of: "ends").count, 1, "premise: the first half is findable")
        XCTAssertEqual(tree.ranges(of: "starts").count, 1, "premise: the second half is findable")
        XCTAssertEqual(tree.ranges(of: "here. And there").count, 0)
    }

    /// The rendered text, not the source — which is the whole reason a find runs on
    /// the measured tree rather than on the string the host handed over.
    func testMarkdownSyntaxIsNotSearchable() {
        let tree = block("A paragraph with **bold** in it.")

        XCTAssertEqual(tree.ranges(of: "bold").count, 1, "premise: the word itself is findable")
        XCTAssertEqual(tree.ranges(of: "**bold**").count, 0)
    }

    /// A link's address is not text a reader can see, so it is not text a find
    /// offers — the same position every browser takes.
    func testALinksDestinationIsNotSearchable() {
        let tree = block("Read [the announcement](https://swift.org/blog) today.")

        XCTAssertEqual(
            tree.ranges(of: "announcement").count, 1, "premise: the label is findable")
        XCTAssertEqual(tree.ranges(of: "swift.org").count, 0)
    }

    /// A marker holds no index positions, so it is not searchable text — the same
    /// rule that keeps it out of a copy.
    func testAListMarkerIsNotSearchable() {
        let tree = block("1. alpha\n2. beta")

        XCTAssertEqual(tree.ranges(of: "beta").count, 1, "premise: the item text is findable")
        XCTAssertEqual(tree.ranges(of: "2.").count, 0)
    }

    func testACodeBlockIsSearchable() {
        let tree = block("```swift\nlet needle = 1\n```")
        XCTAssertEqual(tree.ranges(of: "needle").count, 1)
    }

    func testATablesCellsAreSearchable() {
        let tree = block("| a | b |\n|---|---|\n| needle | thread |")

        XCTAssertEqual(tree.ranges(of: "needle").count, 1)
        // A cell edge is a block edge: what reads as adjacent in the source is not
        // adjacent on screen.
        XCTAssertEqual(tree.ranges(of: "needle thread").count, 0)
    }

    // MARK: - Folding

    func testCaseDiacriticsAndWidthAreFolded() {
        XCTAssertEqual(block("A visit to the Café.").ranges(of: "cafe").count, 1)
        XCTAssertEqual(block("A visit to the cafe.").ranges(of: "CAFÉ").count, 1)
        XCTAssertEqual(block("Katakana ア here.").ranges(of: "\u{FF71}").count, 1)
    }

    /// Non-overlapping, resuming past the hit it just took — `NSTextView`'s
    /// behaviour and every browser's.
    func testMatchesDoNotOverlap() {
        XCTAssertEqual(block("aaaa").ranges(of: "aa").count, 2)
    }

    func testAnEmptyQueryFindsNothing() {
        XCTAssertEqual(block("some words").ranges(of: "").count, 0)
    }

    // MARK: - A capped bubble

    private static func longMessage(lines: Int = 40) -> String {
        (1...lines)
            .map { "line \($0) of a message long enough to be cut short by the line cap" }
            .joined(separator: "\n")
    }

    /// A user's message past the cap keeps its whole string but typesets only the
    /// lines that survived, and a range past those has no rectangle — so a hit
    /// there could be counted but neither highlighted nor scrolled to. Bounded by
    /// what was typeset, which is what a browser does with clipped content.
    func testACappedBubbleFindsNothingPastItsLastLine() throws {
        let bubble = UserMessageBlock(Self.longMessage()).measure(400)

        // The premise: this message really was cut, so the two halves below are
        // genuinely on opposite sides of a cap rather than both on screen.
        XCTAssertNotNil((bubble as? UserMessageBlock.Measured)?.more, "premise: the message was cut")

        XCTAssertEqual(bubble.ranges(of: "line 1 of").count, 1)
        XCTAssertEqual(bubble.ranges(of: "line 40 of").count, 0)

        // And every hit it does report can be drawn.
        for hit in bubble.ranges(of: "message") {
            XCTAssertFalse(bubble.rects(from: hit.lowerBound, to: hit.upperBound).isEmpty)
        }
    }

    func testAnUncappedBubbleIsSearchableThroughout() {
        let bubble = UserMessageBlock("first line\nsecond line").measure(400)
        XCTAssertEqual(bubble.ranges(of: "second").count, 1)
    }

    // MARK: - The transcript

    private var mounted: MountedTranscript!
    private var host: FindHost!

    override func tearDown() {
        mounted?.transcript.endFind()
        mounted?.teardown()
        mounted = nil
        host = nil
        super.tearDown()
    }

    @discardableResult
    private func mount(_ sources: [String], height: CGFloat = 400) -> FindHost {
        mount(FindHost(sources: sources), height: height)
    }

    @discardableResult
    private func mount(_ host: FindHost, height: CGFloat = 400, width: CGFloat = 600) -> FindHost {
        self.host = host
        mounted = MountedTranscript(size: NSSize(width: width, height: height))
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.settle()
        mounted.transcript.reloadData()
        mounted.settle()
        return host
    }

    /// The find as it is on screen: the overlay the transcript presents it in.
    private var overlay: FindOverlayView {
        mounted.transcript.descendants(ofType: FindOverlayView.self)[0]
    }

    /// Where matches are lit, in window coordinates — nothing while the overlay is
    /// hidden, which is what a reader sees then.
    private func litRects() -> [NSRect] {
        overlay.isHidden ? [] : overlay.litRects.map { overlay.convert($0, to: nil) }
    }

    /// Where the current match's bubbles are, in window coordinates.
    private func raisedRects() -> [NSRect] {
        overlay.isHidden ? [] : overlay.indicators.map { $0.convert($0.bounds, to: nil) }
    }

    /// Where a row's own view says `range` is drawn, in window coordinates — what
    /// every lit rectangle is checked against, so no expected position is worked
    /// out here.
    ///
    /// Found through `row(for:)` rather than by position in the tree: cells are
    /// recycled, so tree order is row order only until something scrolls.
    private func rects(of range: Range<Int>, inRow row: Int) throws -> [NSRect] {
        let view = try XCTUnwrap(
            mounted.transcript.descendants(ofType: NSView.self)
                .first { $0 is BlockView && mounted.transcript.row(for: $0) == row }
                as? BlockView,
            "row \(row) has no view on screen")
        return view.rects(forCharacterRange: range).map { view.convert($0, to: nil) }
    }

    /// Where `word` first occurs in `text`, as a range in the flat index space a
    /// plain paragraph shares with its source.
    private func range(of word: String, in text: String) -> Range<Int> {
        let found = (text as NSString).range(of: word)
        return found.lowerBound..<found.upperBound
    }

    func testAFindCountsEveryMatchAndCompletes() async {
        let host = mount(["a needle here", "nothing", "two needle needle here"])

        mounted.transcript.find("needle")
        await mounted.settleFind()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 3)
        XCTAssertEqual(host.findReports.last?.matches, 3)
        XCTAssertEqual(host.findReports.last?.isComplete, true)
        // Reported while it walked as well as at the end, which is the whole
        // point of the callback taking `isComplete`.
        XCTAssertTrue(host.findReports.contains { !$0.isComplete })
    }

    func testAFindWithNoMatchesCompletesAtZero() async {
        let host = mount(["alpha", "beta"])

        mounted.transcript.find("needle")
        await mounted.settleFind()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 0)
        XCTAssertNil(mounted.transcript.indexOfSelectedFindMatch)
        XCTAssertEqual(host.findReports.last?.isComplete, true)
    }

    /// The visible half: the match is lit exactly where its row draws those
    /// characters, and nowhere else — the row beside it matched nothing and has
    /// nothing lit.
    func testAMatchIsLitWhereItsCharactersAreDrawn() async throws {
        mount(["a needle here", "nothing at all"])
        XCTAssertEqual(litRects(), [], "premise: nothing is lit before a find")

        mounted.transcript.find("needle")
        await mounted.settleFind()

        let needle = try rects(of: 2..<8, inRow: 0)
        XCTAssertFalse(needle.isEmpty, "premise: the row places the match somewhere")
        XCTAssertEqual(litRects(), needle)
    }

    /// The match the reader is on is raised over its characters, and the bubble
    /// goes where they go.
    func testTheCurrentMatchIsRaisedAndFollowsFindNext() async throws {
        mount(["needle one", "needle two"])
        mounted.transcript.find("needle")
        await mounted.settleFind()
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 0)

        let first = try rects(of: 0..<6, inRow: 0)
        XCTAssertEqual(raisedRects().count, first.count)
        XCTAssertTrue(zip(raisedRects(), first).allSatisfy { $0.contains($1) })

        mounted.transcript.findNext()
        mounted.settle()
        let second = try rects(of: 0..<6, inRow: 1)
        XCTAssertEqual(raisedRects().count, second.count)
        XCTAssertTrue(zip(raisedRects(), second).allSatisfy { $0.contains($1) })
        XCTAssertFalse(
            raisedRects().contains { $0.intersects(first[0]) }, "the old bubble stayed up")
    }

    /// The overlay lies in the document's coordinates, so a scroll carries every
    /// lit match with its text before anything has laid out again — which is what
    /// keeps a find from swimming under a reader who is scrolling through it.
    func testALitMatchMovesWithItsTextBeforeAnythingLaysOut() async throws {
        let filler = String(repeating: "filler ", count: 200)
        mount(["a needle here\n\n" + filler, filler, filler])
        mounted.transcript.find("needle")
        await mounted.settleFind()
        let before = litRects()
        XCTAssertEqual(before, try rects(of: 2..<8, inRow: 0))

        let clip = mounted.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 40))
        mounted.scrollView.reflectScrolledClipView(clip)

        // No settle: nothing has laid out since the scroll.
        let after = try rects(of: 2..<8, inRow: 0)
        XCTAssertNotEqual(after, before, "premise: the text moved on screen")
        XCTAssertEqual(litRects(), after)
    }

    /// Every move the reader makes reaches the delegate, because the position and
    /// the total are read from two different places and only one of them is an
    /// argument. A find bar wired to this and told only about the count would sit
    /// on a stale "1 of 3" through every ⌘G.
    func testEveryChangeToTheFindIsReported() async {
        let host = mount(["needle one", "needle two", "needle three"])

        mounted.transcript.find("needle")
        await mounted.settleFind()
        let afterScan = host.findReports.count

        mounted.transcript.findNext()
        XCTAssertGreaterThan(host.findReports.count, afterScan, "a move went unreported")
        XCTAssertEqual(host.findReports.last?.matches, 3)

        mounted.transcript.endFind()
        XCTAssertEqual(
            host.findReports.last?.matches, 0, "ending a find left the last count standing")
        XCTAssertEqual(host.findReports.last?.isComplete, true)
    }

    func testEndingAFindTakesTheHighlightsAway() async throws {
        mount(["a needle here"])
        mounted.transcript.find("needle")
        await mounted.settleFind()
        XCTAssertFalse(litRects().isEmpty, "premise: something was lit")
        XCTAssertFalse(raisedRects().isEmpty, "premise: something was raised")

        mounted.transcript.endFind()
        mounted.settle()

        XCTAssertEqual(litRects(), [])
        XCTAssertEqual(raisedRects(), [])
        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 0)
    }

    func testANewQueryReplacesTheOneBeforeIt() async {
        mount(["needle", "thread thread"])

        mounted.transcript.find("needle")
        await mounted.settleFind()
        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 1)

        mounted.transcript.find("thread")
        await mounted.settleFind()
        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 2)
    }

    /// The first hit selects itself, so typing into a find bar jumps — and it is
    /// ordinal zero because the walk runs in reading order.
    func testTheFirstHitSelectsItself() async {
        mount(["nothing", "a needle here"])

        mounted.transcript.find("needle")
        await mounted.settleFind()

        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 0)
    }

    /// Rows tall enough that only one is on screen at a time, so "where the reader
    /// is looking" is unambiguous.
    @discardableResult
    private func mountScreenfuls(_ marked: Set<Int>, count: Int = 10) -> FindHost {
        let filler = String(repeating: "filler ", count: 200)
        return mount(
            (0..<count).map { marked.contains($0) ? "a needle here\n\n" + filler : filler },
            height: 300)
    }

    /// A find starts where the reader is, not at the top of the history.
    ///
    /// The bug this pins was plain the first time the demo was used: search for a
    /// word that is on screen, and the transcript scrolls away to a different one
    /// several thousand rows up.
    func testAFindStartsFromTheViewportRatherThanTheTop() async {
        mountScreenfuls([0, 6])

        mounted.transcript.scrollToRow(at: 6, scrollPosition: .top)
        mounted.settle()

        mounted.transcript.find("needle")
        await mounted.settleFind()

        // The hit in row 6, which is ordinal 1 — the one in row 0 is still counted
        // and still highlighted, it is just not where the reader was sent.
        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 2)
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 1)
        XCTAssertTrue(
            mounted.scrollView.contentView.documentVisibleRect
                .intersects(mounted.documentRect(ofRow: 6)),
            "the reader was moved away from the hit in front of them")
    }

    /// And when every hit is above the reader, it wraps — rather than leaving a
    /// find with matches and nothing selected.
    func testAFindWithEveryHitAboveTheReaderWrapsToTheFirst() async {
        mountScreenfuls([0, 1])

        mounted.transcript.scrollToRow(at: 9, scrollPosition: .top)
        mounted.settle()

        mounted.transcript.find("needle")
        await mounted.settleFind()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 2)
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 0)
    }

    func testFindNextWalksTheHitsInOrderAndWraps() async {
        mount(["needle one", "needle two", "needle three"])

        mounted.transcript.find("needle")
        await mounted.settleFind()
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 0)

        mounted.transcript.findNext()
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 1)
        mounted.transcript.findNext()
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 2)
        mounted.transcript.findNext()
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 0, "did not wrap")

        mounted.transcript.findPrevious()
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 2, "did not wrap backwards")
    }

    /// Two hits in one row are two ordinals, which is what makes "4 of 51" count
    /// matches rather than rows.
    func testTwoHitsInOneRowAreTwoOrdinals() async {
        mount(["needle and needle again"])

        mounted.transcript.find("needle")
        await mounted.settleFind()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 2)
        mounted.transcript.findNext()
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 1)
    }

    /// Moving to a hit off screen brings it on screen.
    func testFindNextScrollsToTheRowItSelected() async {
        // Each row a screenful, so the last one is far below the viewport.
        mount((0..<12).map { "needle \($0)\n\n" + String(repeating: "filler ", count: 200) })
        mounted.transcript.scrollToRow(at: 0, scrollPosition: .top)
        mounted.settle()

        mounted.transcript.find("needle")
        await mounted.settleFind()
        for _ in 0..<8 { mounted.transcript.findNext() }
        mounted.settle()

        let visible = mounted.scrollView.contentView.documentVisibleRect
        XCTAssertTrue(
            visible.intersects(mounted.documentRect(ofRow: 8)),
            "the selected hit's row is not on screen")
    }

    /// A row that leaves the viewport and comes back is a recycled cell — possibly
    /// another row's — and is lit again on the way in, where its characters are.
    func testARowScrolledAwayAndBackKeepsItsHighlight() async throws {
        // Each row a screenful, so scrolling to the last one takes the first out of
        // the viewport entirely.
        let filler = String(repeating: "filler ", count: 200)
        mount((0..<8).map { $0 == 0 ? "a needle here\n\n" + filler : filler })

        mounted.transcript.find("needle")
        await mounted.settleFind()
        XCTAssertEqual(litRects(), try rects(of: 2..<8, inRow: 0))

        mounted.transcript.scrollToRow(at: 7, scrollPosition: .top)
        mounted.settle()
        XCTAssertEqual(litRects(), [], "premise: the row really left the screen")
        mounted.transcript.scrollToRow(at: 0, scrollPosition: .top)
        mounted.settle()

        XCTAssertEqual(litRects(), try rects(of: 2..<8, inRow: 0))
    }

    /// The index space a hit is stated in does not depend on the width, so a
    /// resize lights every match where its characters are now and loses none.
    func testHighlightsSurviveAWidthChange() async throws {
        let text = "a paragraph long enough that narrowing it rewraps the line, and a needle"
        mount([text])
        let needle = range(of: "needle", in: text)

        mounted.transcript.find("needle")
        await mounted.settleFind()
        let wide = try rects(of: needle, inRow: 0)
        XCTAssertEqual(litRects(), wide)

        mounted.setContentWidth(360)
        await mounted.settleWidthChange()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 1)
        let narrow = try rects(of: needle, inRow: 0)
        XCTAssertNotEqual(narrow, wide, "premise: the rewrap really did move the match")
        XCTAssertEqual(litRects(), narrow)
    }

    /// Removing a row drops its hits at the sweep that drops its measurement,
    /// rather than leaving a count that names text nobody has.
    func testRemovingARowDropsItsHits() async {
        let host = mount(["needle one", "needle two"])

        mounted.transcript.find("needle")
        await mounted.settleFind()
        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 2)

        host.removeRow(at: 0)
        mounted.transcript.removeRows(at: IndexSet(integer: 0))
        mounted.settle()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 1)
        XCTAssertEqual(host.findReports.last?.matches, 1)
    }

    /// The arm that exists for rows the cache cannot answer for.
    ///
    /// Reached two ways in production and only one of them is reproducible here. A
    /// row nothing has ever measured is the common one — a plain batched
    /// `insertRows` leaves a share of a long transcript that way, since the table
    /// asks about a working set rather than every row — but *which* share is
    /// AppKit's tiling heuristic and not something a test can pin: written against
    /// it, this passed with the arm deleted.
    ///
    /// A row whose content moved without the host announcing it reaches the same
    /// branch by the same route, deterministically: `RowCache` believes an entry
    /// only as far as its content matches, so what it holds is refused exactly as
    /// if it were not there, and the find has to build a tree rather than skip the
    /// row.
    func testARowTheCacheCannotAnswerForIsStillSearched() async {
        let host = mount(["nothing here at all"])

        host.setSource("a needle appeared", at: 0)

        mounted.transcript.find("needle")
        await mounted.settleFind()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 1)
    }
    /// The dimming stops at the transcript's edge. The overlay is taller than the
    /// viewport on purpose — rows arriving from past the edge are lit before they
    /// are seen — so without a clip the extra reaches whatever the host put above
    /// the transcript: a find bar, a tab bar. Read from the composited window,
    /// since a clip is what the window server applies and a frame does not show.
    func testTheDimmingStaysInsideTheTranscript() async throws {
        let window = TestWindow.make(contentSize: NSSize(width: 600, height: 400))
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        let root = NSView()
        window.contentView = root
        let chrome = WhiteView()
        let transcript = TranscriptView()
        let host = FindHost(sources: ["A paragraph that mentions Claude."])
        // The host's bar goes in first and the transcript over it, which is the
        // order a stack view or a plain `addSubview` sequence gives.
        for view in [chrome, transcript] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: root.topAnchor),
            chrome.heightAnchor.constraint(equalToConstant: 60),
            transcript.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            transcript.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for view in [chrome, transcript] as [NSView] {
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        }
        transcript.dataSource = host
        transcript.delegate = host
        root.layoutSubtreeIfNeeded()
        transcript.reloadData()
        root.layoutSubtreeIfNeeded()

        transcript.find("claude")
        await transcript.finding?.value
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(transcript.numberOfFindMatches, 1, "premise: the find is up")
        let overlay = transcript.descendants(ofType: FindOverlayView.self)[0]
        XCTAssertGreaterThan(
            overlay.convert(overlay.bounds, to: nil).maxY, transcript.convert(transcript.bounds, to: nil).maxY,
            "premise: the overlay reaches past the transcript's top")

        let pixels = try await WindowCapture.bitmap(of: chrome)
        let brightness = try XCTUnwrap(
            pixels.colorAt(x: 300, y: 30)?.usingColorSpace(.deviceRGB)?.brightnessComponent)
        XCTAssertGreaterThan(brightness, 0.97, "the find dimmed the host's bar above the transcript")
    }

    // MARK: - A find follows the transcript

    /// A find replaces the previous one's count straight away, rather than leaving
    /// it on screen beside the new query until the walk has something to say.
    func testANewFindReportsBeforeItHasWalked() async {
        let host = mount(["needle", "needle", "needle"])
        mounted.transcript.find("needle")
        await mounted.settleFind()
        let before = host.findReports.count

        mounted.transcript.find("nothing matches this")

        XCTAssertEqual(host.findReports.count, before + 1, "the new find said nothing")
        XCTAssertEqual(host.findReports.last?.matches, 0)
        XCTAssertEqual(host.findReports.last?.isComplete, false)
    }

    /// A row whose content was replaced loses the hits found in its old text and
    /// gains the ones in its new text — the count, and what is drawn.
    func testAReloadedRowIsSearchedAgain() async throws {
        let host = mount(["a needle here", "nothing"])
        mounted.transcript.find("needle")
        await mounted.settleFind()
        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 1)

        host.setSource("rewritten without it", at: 0)
        host.setSource("needle, needle", at: 1)
        mounted.transcript.reloadRows(at: IndexSet([0, 1]))
        mounted.settle()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 2)
        XCTAssertEqual(host.findReports.last?.matches, 2)
        XCTAssertEqual(
            litRects(), try rects(of: 0..<6, inRow: 1) + rects(of: 8..<14, inRow: 1),
            "row 0 is still lit at its old hit, or row 1's new ones are not")
    }

    /// The streaming case: a row that grows a match while a find is up has it
    /// counted as it arrives.
    func testAStreamingRowIsFoundAsItGrows() async {
        let host = mount(["The answer so far"])
        mounted.transcript.find("needle")
        await mounted.settleFind()
        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 0)

        host.setSource("The answer so far mentions a needle", at: 0)
        mounted.transcript.reloadRows(at: IndexSet(integer: 0))
        mounted.settle()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 1)
    }

    /// Rows appended after the walk finished are searched: the walk resumes for
    /// them, and says it is complete again when it has.
    func testRowsAppendedAfterAFindAreSearched() async {
        let host = mount(["needle one"])
        mounted.transcript.find("needle")
        await mounted.settleFind()
        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 1)

        host.insert(["needle two", "needle three"], at: 1)
        mounted.transcript.insertRows(at: IndexSet(1..<3))
        await mounted.settleFind()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 3)
        XCTAssertEqual(host.findReports.last?.matches, 3)
        XCTAssertEqual(host.findReports.last?.isComplete, true)
    }

    /// History prepended while the walk is under way — after it has filed rows,
    /// and while its next slice is out on the pool — is searched, and nothing is
    /// counted twice: not the rows the walk had passed, and not the ones the
    /// prepend renumbered under the slice it was waiting for.
    ///
    /// The timing is the host's own, not a guess: the prepend is scheduled from
    /// the walk's first report, which lands after one slice is filed and before
    /// the next is answered — the pool's answer resumes the walk on the main actor
    /// behind it.
    func testRowsPrependedDuringTheWalkAreCountedOnce() async {
        let host = mount((0..<1_000).map { $0 % 10 == 0 ? "needle \($0)" : "hay \($0)" })
        var prepended = false
        host.onFindReport = { [unowned self] matches, isComplete in
            guard !prepended, matches > 0, !isComplete else { return }
            prepended = true
            Task { @MainActor in
                host.insert((0..<50).map { "needle history \($0)" }, at: 0)
                self.mounted.transcript.insertRows(at: IndexSet(0..<50))
            }
        }

        mounted.transcript.find("needle")
        await mounted.settleFind()

        XCTAssertTrue(prepended, "premise: the prepend landed during the walk")
        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 150)
        XCTAssertEqual(host.findReports.last?.matches, 150)
        XCTAssertEqual(host.findReports.last?.isComplete, true)
    }

    /// Removing a matched row above the reader's hit moves the hit's number down
    /// with it, so "3 of 3" becomes "2 of 2" and the next ⌘G goes somewhere.
    func testRemovingAHitAboveTheSelectionRenumbersIt() async {
        let host = mount(["needle zero", "needle one", "needle two"])
        mounted.transcript.find("needle")
        await mounted.settleFind()
        mounted.transcript.findNext()
        mounted.transcript.findNext()
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 2)

        host.removeRow(at: 0)
        mounted.transcript.removeRows(at: IndexSet(integer: 0))
        mounted.settle()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 2)
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 1)
        mounted.transcript.findNext()
        XCTAssertEqual(mounted.transcript.indexOfSelectedFindMatch, 0, "⌘G stood still")
    }

    /// `reloadData()` may hand any row anything; a find up walks again and ends
    /// with the count of what the rows hold now.
    func testReloadDataWalksAFindAgain() async {
        let host = mount(["needle", "hay"])
        mounted.transcript.find("needle")
        await mounted.settleFind()

        host.setSource("hay", at: 0)
        host.setSource("needle needle", at: 1)
        mounted.transcript.reloadData()
        await mounted.settleFind()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 2)
        XCTAssertEqual(host.findReports.last?.isComplete, true)
    }

    // MARK: - Where a hit lands

    /// A hit several screens down one tall row is brought on screen itself — not
    /// just the row's nearest edge, which would leave the match a page away.
    ///
    /// Checked against where the row's own view draws the hit, converted through
    /// the real view tree, so a wrong offset anywhere between the block and the
    /// clip shows up here.
    func testAHitDeepInATallRowIsScrolledIntoView() async throws {
        let filler = (1...60).map { "Paragraph \($0) with ordinary words in it." }
        mount([filler.joined(separator: "\n\n") + "\n\nThe needle is here."], height: 300)
        mounted.transcript.scrollToRow(at: 0, scrollPosition: .top)
        mounted.settle()

        mounted.transcript.find("needle")
        await mounted.settleFind()

        let view = try XCTUnwrap(mounted.transcript.descendants(ofType: BlockView.self).first)
        let block = try XCTUnwrap(view.block)
        let hit = try XCTUnwrap(block.ranges(of: "needle").first)
        let rect = try XCTUnwrap(block.rects(from: hit.lowerBound, to: hit.upperBound).first)
        let clip = mounted.scrollView.contentView
        XCTAssertTrue(
            clip.bounds.contains(view.convert(rect, to: clip)),
            "the hit is at \(view.convert(rect, to: clip)), the viewport is \(clip.bounds)")
    }

    // MARK: - A capped bubble and the width

    /// A user message cut at its line cap shows more of itself at a wider width,
    /// so a hit can be on screen at one width and past the cut at another. The
    /// count follows the width once it settles, rather than counting a hit that
    /// can no longer be seen.
    func testACappedBubblesHitsFollowTheWidth() async {
        let lines = (1...40).map { String(format: "item%02d alpha beta gamma", $0) }
        let host = mount(
            FindHost(contents: [.userMessage(lines.joined(separator: "\n"))]), width: 800)

        mounted.transcript.find("item09")
        await mounted.settleFind()
        XCTAssertEqual(
            mounted.transcript.numberOfFindMatches, 1,
            "premise: at this width the ninth line is above the cut")

        mounted.setContentWidth(200)
        await mounted.settleWidthChange()
        await mounted.settleFind()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 0)
        XCTAssertEqual(host.findReports.last?.matches, 0)
    }

    // MARK: - A host's own rows

    /// A host's `.view` row is neither searched nor highlighted, and the walk
    /// goes on through it to the rows after.
    func testAViewRowIsSkippedAndTheWalkContinuesPastIt() async {
        mount(FindHost(contents: [.markdown("needle one"), .view, .markdown("needle three")]))

        mounted.transcript.find("needle")
        await mounted.settleFind()

        XCTAssertEqual(mounted.transcript.numberOfFindMatches, 2)
        XCTAssertEqual(host.findReports.last?.isComplete, true)
    }
}

/// Answers each row from a list of contents, draws `.view` rows with a
/// `HostRowView`, and records what the transcript reported about the find.
@MainActor
private final class FindHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    private var rows: [(id: UUID, content: TranscriptRowContent, text: String)]

    private(set) var findReports: [(matches: Int, isComplete: Bool)] = []

    /// Called with each report as it arrives, for a test that acts mid-walk.
    var onFindReport: ((Int, Bool) -> Void)?

    convenience init(sources: [String]) {
        self.init(contents: sources.map { .markdown($0) })
    }

    init(contents: [TranscriptRowContent]) {
        rows = contents.map { (UUID(), $0, "") }
        super.init()
    }

    /// Changes a row's text. Tests that announce it call `reloadRows` after;
    /// one that does not is reaching a refused cache entry on purpose.
    func setSource(_ source: String, at index: Int) {
        rows[index].content = .markdown(source)
    }

    func insert(_ sources: [String], at index: Int) {
        rows.insert(contentsOf: sources.map { (UUID(), .markdown($0), "") }, at: index)
    }

    func removeRow(at index: Int) {
        rows.remove(at: index)
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        TranscriptRow(id: rows[row].id, content: rows[row].content)
    }

    func transcriptView(
        _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
    ) -> CGFloat {
        40
    }

    func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
        transcriptView.makeView(withIdentifier: HostRowView.identifier) { HostRowView() }
    }

    func transcriptView(
        _ transcriptView: TranscriptView, didUpdateFindMatches matches: Int, isComplete: Bool
    ) {
        findReports.append((matches, isComplete))
        onFindReport?(matches, isComplete)
    }
}

/// A host's row view — the transcript draws no find on it.
@MainActor
private final class HostRowView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("FindTests.row")
}

/// A plain white bar: the host's chrome, in the only colour the dimming shows on.
private final class WhiteView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
    }
}
