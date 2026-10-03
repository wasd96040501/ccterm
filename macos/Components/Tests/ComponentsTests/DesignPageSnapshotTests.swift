import AppKit
import XCTest

/// The style page rendered whole, for review: a wide window and a narrow one,
/// light and dark, to `/tmp/ccterm-screenshots/Design-<width>-<scheme>.png`.
/// Each is the built `ComponentsDesign` run as `--render`, in English
/// (`-AppleLanguages '(en)'` — a test process can't change its own language,
/// Foundation fixes it at launch): the executable parks its window off the
/// screen's corner, captures it as the window server composites it
/// (`CompositedCapture`), writes the PNG and exits. No window is ever shown.
/// Skipped unless named: `make test-ui FILTER=DesignPageSnapshotTests`.
@MainActor
final class DesignPageSnapshotTests: XCTestCase {
    func testThePageFollowsTheWindowsWidth() throws {
        let directory = "/tmp/ccterm-screenshots"
        for width in [1240, 600] {
            for scheme in ["light", "dark"] {
                try render(width: width, scheme: scheme, into: directory)
                let url = URL(fileURLWithPath: directory).appendingPathComponent("Design-\(width)-\(scheme).png")
                let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
                XCTAssertEqual(rep.pixelsWide, width * 2, "the page is the window's width")
            }
        }
    }

    /// Runs the page's executable, which sits beside the test bundle.
    private func render(width: Int, scheme: String, into directory: String) throws {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("ComponentsDesign")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-AppleLanguages", "(en)", "--render", directory, "\(width)", scheme]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus == 75 { throw XCTSkip("no capture could be had: \(message)") }
        XCTAssertEqual(process.terminationStatus, 0, "ComponentsDesign --render failed: \(message)")
    }
}
