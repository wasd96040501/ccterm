import AppKit
import XCTest

@testable import TranscriptKit

/// Measuring runs off the main actor, and the result crosses back.
///
/// The claim the two-protocol split exists to make good on: a `Layout` is pure,
/// so a host may typeset on a background task and hand the `MarkdownBlock` over.
///
/// **What this catches, precisely:** that measuring on another thread runs, and
/// that it produces the same answer as measuring on the main one. Both were
/// worth pinning — an `@MainActor` annotation appearing anywhere in the layout
/// path makes the first fail to compile.
///
/// **What it does not catch:** a main-thread-only AppKit call sneaking back in.
/// Verified rather than assumed — restoring the `NSFontManager` call that
/// `MarkdownInline` used to make leaves this suite green, because the
/// main-thread checker is not enabled under `swift test`. `@unchecked Sendable`
/// closes off the other half of the net for the same reason: it is the exact
/// annotation that turns off the compiler's transfer check.
///
/// So the prohibition on `NSFontManager` and friends is held by review, not by
/// this file. Anything stronger would need the checker enabled in the test
/// environment.
final class OffMainLayoutTests: XCTestCase {

    private static let source = """
        # Heading

        Body with *emphasis*, **strong**, `code`, and a [link](https://example.com).

        > A quote holding a list:
        >
        > 1. first
        > 10. tenth

        ```swift
        let x = 1
        ```

        ---
        """

    func testDocumentMeasuresOffTheMainActor() async throws {
        let block = try await Task.detached {
            XCTAssertFalse(Thread.isMainThread, "the point of this test is the other thread")
            return MarkdownLayout.make(Self.source).measure(400)
        }.value

        // Non-trivial on both axes: an empty result would pass every structural
        // assertion while proving nothing ran.
        XCTAssertEqual(block.size.width, 400)
        XCTAssertGreaterThan(block.size.height, 100)
        XCTAssertGreaterThan(block.length, 0)
        XCTAssertTrue(block.text(from: 0, to: block.length).contains("emphasis"))
    }

    /// The same document, measured on each side, comes out the same size — so
    /// "it ran" and "it ran correctly" are separate assertions.
    @MainActor
    func testOffMainAndOnMainAgree() async throws {
        let onMain = MarkdownLayout.make(Self.source).measure(400)
        let offMain = try await Task.detached { MarkdownLayout.make(Self.source).measure(400) }
            .value

        XCTAssertEqual(offMain.size.height, onMain.size.height, accuracy: 0.5)
        XCTAssertEqual(offMain.length, onMain.length)
    }
}
