import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Opt-in (filename ends in `SnapshotTests`; see CLAUDE.md) visual review of
/// the **AppKit** `ContextBarView` — the replacement for the SwiftUI
/// context-usage `barTrack` (whose look lives inside the `ContextBreakdownView`
/// popover in `ContextRingButton.swift`). Renders the bar by wrapping the bare
/// custom-`draw(_:)` `NSView` in a throwaway VC and driving
/// `ViewSnapshot.renderViewController` (plan §9).
///
/// Two states × two appearances:
///
///   - representative breakdown (active accent-stepped segments → deferred /
///     buffer gray → trailing Free space) in light + dark — eyeball the accent
///     step, the gray tail, the rounded clip, and that semantic colors resolve
///     correctly per appearance (the cgColor-freeze the layer-backed leaves had
///     to guard does NOT apply to a `draw(_:)` view).
///   - the empty placeholder (no usage → flat 0% track) in light + dark.
@MainActor
final class ContextBarViewSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRepresentativeBreakdownLightAndDark() throws {
        let usage = try representativeUsage()
        let canvas = CGSize(width: 420, height: 80)

        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let controller = makeBar(canvas: canvas, appearance: appearanceName) {
                ContextBarView(usage: usage)
            }
            let image = ViewSnapshot.renderViewController(controller, size: canvas, settle: 0.4)
            let url = ViewSnapshot.writePNG(image, name: "ContextBarView-\(suffix)")
            attach(url, name: "ContextBarView-\(suffix).png")
            XCTAssertGreaterThanOrEqual(image.size.width, 380)
        }
    }

    func testEmptyPlaceholderLightAndDark() throws {
        let canvas = CGSize(width: 420, height: 80)

        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let controller = makeBar(canvas: canvas, appearance: appearanceName) {
                ContextBarView(usage: nil)
            }
            let image = ViewSnapshot.renderViewController(controller, size: canvas, settle: 0.4)
            let url = ViewSnapshot.writePNG(image, name: "ContextBarView-empty-\(suffix)")
            attach(url, name: "ContextBarView-empty-\(suffix).png")
            XCTAssertGreaterThanOrEqual(image.size.width, 380)
        }
    }

    // MARK: - Fixtures

    /// Same representative breakdown the CI-gate `ContextBarLayoutTests` uses:
    /// two active rows, one deferred, the autocompact buffer, and Free space.
    private func representativeUsage() throws -> ContextUsage {
        let raw: [String: Any] = [
            "categories": [
                ["name": "Messages", "tokens": 74_600],
                ["name": "System tools", "tokens": 11_600],
                ["name": "System tools (deferred)", "tokens": 19_157, "isDeferred": true],
                ["name": "Autocompact buffer", "tokens": 33_000],
                ["name": "Free space", "tokens": 869_600],
            ],
            "totalTokens": 138_357,
            "maxTokens": 1_000_000,
            "rawMaxTokens": 1_000_000,
            "percentage": 14,
        ]
        return try ContextUsage(json: raw)
    }

    // MARK: - Helpers

    /// A throwaway VC whose view is a `windowBackgroundColor` panel pinned to
    /// the requested appearance; the bar is centered vertically and pinned to
    /// the popover-ish content width with horizontal insets.
    private func makeBar(
        canvas: CGSize, appearance: NSAppearance.Name, make: () -> ContextBarView
    ) -> NSViewController {
        let container = NSView(frame: NSRect(origin: .zero, size: canvas))
        container.wantsLayer = true
        container.appearance = NSAppearance(named: appearance)
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let bar = make()
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            bar.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: ContextBarView.barHeight),
        ])

        let vc = NSViewController()
        vc.view = container
        return vc
    }

    private func attach(_ url: URL, name: String) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
