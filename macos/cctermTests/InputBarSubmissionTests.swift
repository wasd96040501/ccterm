import AppKit
import XCTest

@testable import ccterm

/// Logic test for the types lifted out of `InputBarView2` into the
/// SwiftUI-free `InputBarSubmission.swift` (`Submission` + `Attachment` /
/// `Attachment.Kind`). The lift was a pure relocation, so these assertions
/// pin the *shape* the future AppKit `InputBarController` and the
/// `submitSessionInput` helper consume: the memberwise `Submission` init,
/// `Attachment`'s custom `==` (thumbnail-excluded), `Attachment.Kind`'s
/// synthesized `Equatable`, and the default-`id` behavior — plus a
/// composition check that the two `Kind` cases destructure into the exact
/// shapes the `Submission` initializer (and downstream `submitSessionInput`)
/// consume.
final class InputBarSubmissionTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Submission memberwise init

    /// `Submission(text:images:filePaths:)` stores every field verbatim.
    /// This is the public surface `submitSessionInput` reads.
    func testSubmissionMemberwiseInitStoresFields() throws {
        let s = Submission(
            text: "hi",
            images: [(data: Data([0x1]), mediaType: "image/png")],
            filePaths: ["/a"]
        )
        XCTAssertEqual(s.text, "hi")
        XCTAssertEqual(s.filePaths, ["/a"])
        XCTAssertEqual(s.images.count, 1)
        XCTAssertEqual(s.images[0].mediaType, "image/png")
        XCTAssertEqual(s.images[0].data, Data([0x1]))
    }

    /// All three payload slots may be empty simultaneously (the type is a
    /// dumb carrier — `canSend` gates non-empty-ness upstream, not the init).
    func testSubmissionAcceptsEmptyPayload() throws {
        let s = Submission(text: "", images: [], filePaths: [])
        XCTAssertTrue(s.text.isEmpty)
        XCTAssertTrue(s.images.isEmpty)
        XCTAssertTrue(s.filePaths.isEmpty)
    }

    // MARK: - Attachment equality (thumbnail excluded)

    /// Two attachments with identical id/kind/filename but DIFFERENT
    /// thumbnails compare equal — `==` deliberately excludes the NSImage
    /// (which is not Equatable).
    func testAttachmentEqualityExcludesThumbnail() throws {
        let u = UUID()
        let a = Attachment(
            id: u, kind: .file(path: "/a"), thumbnail: NSImage(), filename: "a")
        let b = Attachment(
            id: u,
            kind: .file(path: "/a"),
            thumbnail: NSImage(size: NSSize(width: 9, height: 9)),
            filename: "a")
        XCTAssertEqual(a, b)
    }

    /// A different id, kind, OR filename each break equality.
    func testAttachmentEqualityDiscriminatesIdKindFilename() throws {
        let u = UUID()
        let base = Attachment(
            id: u, kind: .file(path: "/a"), thumbnail: NSImage(), filename: "a")

        let differentId = Attachment(
            id: UUID(), kind: .file(path: "/a"), thumbnail: NSImage(), filename: "a")
        XCTAssertNotEqual(base, differentId)

        let differentKind = Attachment(
            id: u, kind: .file(path: "/b"), thumbnail: NSImage(), filename: "a")
        XCTAssertNotEqual(base, differentKind)

        let differentFilename = Attachment(
            id: u, kind: .file(path: "/a"), thumbnail: NSImage(), filename: "b")
        XCTAssertNotEqual(base, differentFilename)
    }

    // MARK: - Attachment.Kind synthesized Equatable

    func testAttachmentKindEquality() throws {
        let d1 = Data([0x1])
        let d2 = Data([0x2])
        XCTAssertNotEqual(
            Attachment.Kind.image(data: d1, mediaType: "image/png"),
            Attachment.Kind.image(data: d2, mediaType: "image/png"))
        XCTAssertEqual(
            Attachment.Kind.image(data: d1, mediaType: "image/png"),
            Attachment.Kind.image(data: d1, mediaType: "image/png"))
        XCTAssertNotEqual(
            Attachment.Kind.file(path: "/a"), Attachment.Kind.file(path: "/b"))
        XCTAssertNotEqual(
            Attachment.Kind.image(data: d1, mediaType: "image/png"),
            Attachment.Kind.file(path: "/a"))
    }

    // MARK: - Default id

    /// Two attachments built without an explicit id get DISTINCT ids — the
    /// `id: UUID = UUID()` default must fire per call (guards it surviving
    /// the move).
    func testAttachmentDefaultIdIsUnique() throws {
        let a = Attachment(kind: .file(path: "/a"), thumbnail: NSImage(), filename: "a")
        let b = Attachment(kind: .file(path: "/a"), thumbnail: NSImage(), filename: "a")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Submission composes from folded attachment arrays

    /// `Attachment.kind` is the discriminator a caller folds over to split
    /// images from file paths; this asserts the two `Kind` cases destructure
    /// to the exact tuple/string shapes the `Submission` initializer (and
    /// downstream `submitSessionInput`) consume — guarding the lifted types
    /// still compose correctly after the relocation. This does NOT purport to
    /// verify `InputBarView2.handleSend`'s private fold (which lives on a
    /// SwiftUI `@State`-driven `View` and is unreachable headlessly without a
    /// forbidden seam); the fold logic moves to `InputBarController` in Phase
    /// 1, where a round-trip test can drive it directly.
    func testSubmissionComposesFromFoldedAttachmentArrays() throws {
        let imageData = Data([0xAA, 0xBB])
        let attachments: [Attachment] = [
            Attachment(
                kind: .image(data: imageData, mediaType: "image/png"),
                thumbnail: NSImage(),
                filename: "shot.png"),
            Attachment(
                kind: .file(path: "/tmp/notes.txt"),
                thumbnail: NSImage(),
                filename: "notes.txt"),
        ]

        // Fold the attachments by their `Kind` discriminator into the two
        // payload slots `Submission` carries (images vs file paths).
        var images: [(data: Data, mediaType: String)] = []
        var filePaths: [String] = []
        for attachment in attachments {
            switch attachment.kind {
            case .image(let data, let mediaType):
                images.append((data: data, mediaType: mediaType))
            case .file(let path):
                filePaths.append(path)
            }
        }

        let submission = Submission(text: "caption", images: images, filePaths: filePaths)
        XCTAssertEqual(submission.text, "caption")
        XCTAssertEqual(submission.images.count, 1)
        XCTAssertEqual(submission.images[0].data, imageData)
        XCTAssertEqual(submission.images[0].mediaType, "image/png")
        XCTAssertEqual(submission.filePaths, ["/tmp/notes.txt"])
    }
}
