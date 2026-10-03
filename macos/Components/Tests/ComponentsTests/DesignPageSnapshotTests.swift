import AppKit
import XCTest

@testable import ComponentsDesign

/// The style page rendered for review: every section at a wide window and a
/// narrow one, light and dark, to
/// `<package>/.build/design/Design-<section>-<width>-<scheme>.png` — in the
/// checkout's own build directory, so worktrees never overwrite each other's — one PNG
/// per section, since the whole page is taller than a capture can be. Each is
/// the built `ComponentsDesign` run as `--render`, in English
/// (`-AppleLanguages '(en)'` — a test process can't change its own language,
/// Foundation fixes it at launch): the executable parks its window off the
/// screen's corner, captures it as the window server composites it
/// (`CompositedCapture`), writes the PNGs and exits. No window is ever shown.
/// Skipped unless named: `make test-ui FILTER=DesignPageSnapshotTests`.
@MainActor
final class DesignPageSnapshotTests: XCTestCase {
    func testEverySectionIsRenderedAtTheWindowsWidth() throws {
        let directory = Self.buildDirectory.appendingPathComponent("design").path
        let slugs = Design.sections().map { Design.fileSlug($0.title) }
        XCTAssertFalse(slugs.isEmpty)
        for width in [1240, 600] {
            for scheme in ["light", "dark"] {
                try render(width: width, scheme: scheme, into: directory)
                for slug in slugs {
                    let url = URL(fileURLWithPath: directory)
                        .appendingPathComponent("Design-\(slug)-\(width)-\(scheme).png")
                    let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)), url.lastPathComponent)
                    XCTAssertEqual(rep.pixelsWide, width * 2, "\(url.lastPathComponent) is the window's width")
                }
            }
        }
    }

    /// `.build`: two above the products' directory, which holds the test
    /// bundle and the page's executable.
    private static var buildDirectory: URL {
        productsDirectory.deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var productsDirectory: URL {
        Bundle(for: DesignPageSnapshotTests.self).bundleURL.deletingLastPathComponent()
    }

    /// Runs the page's executable, which sits beside the test bundle.
    private func render(width: Int, scheme: String, into directory: String) throws {
        let executable = Self.productsDirectory.appendingPathComponent("ComponentsDesign")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-AppleLanguages", "(en)", "--render", directory, "\(width)", scheme]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        // Every wait has a deadline: the executable stops its own sections at
        // 120 s each; this stops it all.
        let deadline = Date(timeIntervalSinceNow: 1800)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning {
            process.terminate()
            XCTFail("ComponentsDesign --render took over 30 minutes")
            return
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus == 75 { throw XCTSkip("no capture could be had: \(message)") }
        XCTAssertEqual(process.terminationStatus, 0, "ComponentsDesign --render failed: \(message)")
    }
}
