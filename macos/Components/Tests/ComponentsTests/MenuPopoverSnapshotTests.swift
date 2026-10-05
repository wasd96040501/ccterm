import AppKit
import DisplayModels
import XCTest

@testable import Components
@testable import ComponentsDesign

/// Every menu open in its real popover, as the window server composites it —
/// frame, arrow, material, selection — light and dark, to
/// `/tmp/ccterm-screenshots/MenuPopover-<name>-<scheme>.png` for review. The
/// button's window is far off screen and the popover's is parked at the
/// screen's corner with one point showing, as the style page's render parks
/// its window, so nothing shows on the reader's display.
@MainActor
final class MenuPopoverSnapshotTests: XCTestCase {
    private static let out = URL(fileURLWithPath: "/tmp/ccterm-screenshots", isDirectory: true)

    func testEveryMenuOpen() async throws {
        typealias F = ComposerFixtures
        let menus: [(String, MenuContent, (NSWindow) -> Void)] = [
            ("model", ComposerMenu.content(of: .model, in: MenuFixtures.composer), { _ in }),
            ("model-working", ComposerMenu.content(of: .model, in: F.responding), { _ in }),
            ("effort", ComposerMenu.content(of: .effort, in: F.idle), { _ in }),
            ("effort-selected", ComposerMenu.content(of: .effort, in: F.idle), Self.press(.downArrow, times: 2)),
            ("mode-fast", ComposerMenu.content(of: .mode, in: F.fastRing), { _ in }),
            ("folder", MenuFixtures.folder, { _ in }),
            ("branch", MenuFixtures.branch(), { _ in }),
            ("branch-selected", MenuFixtures.branch(), Self.press(.downArrow, times: 2)),
            ("branch-pr", MenuFixtures.branch(query: "#327"), { _ in }),
            ("branch-none", MenuFixtures.branch(query: "zzz"), { _ in }),
        ]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        for scheme in ["light", "dark"] {
            for (name, content, prepare) in menus {
                let stage = Stage(appearance: NSAppearance(named: scheme == "light" ? .aqua : .darkAqua))
                stage.popover.configure(with: content)
                stage.popover.show(from: stage.button, above: false)
                let window = try XCTUnwrap(stage.popover.contentViewController?.view.window)
                prepare(window)
                let url = Self.out.appendingPathComponent("MenuPopover-\(name)-\(scheme).png")
                do {
                    let image = try await CompositedCapture.image(of: window)
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                } catch is CompositedCapture.Unavailable {
                    // No display to composite on: the content drawn flat, its
                    // material missing, which still shows the rows and the selection.
                    let view = try XCTUnwrap(stage.popover.contentViewController?.view)
                    view.layoutSubtreeIfNeeded()
                    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(
                        to: url.deletingPathExtension().appendingPathExtension("flat.png"))
                }
                stage.popover.close()
                stage.window.close()
            }
        }
    }

    /// Presses `key` `times` in the popover, as the keyboard does.
    private static func press(_ key: Key, times: Int) -> (NSWindow) -> Void {
        { window in
            for _ in 0..<times {
                guard
                    let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: key.characters,
                        charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code)
                else { continue }
                window.sendEvent(event)
            }
        }
    }

    enum Key {
        case downArrow

        var characters: String { String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)) }
        var code: UInt16 { 125 }
    }
}

/// Two menu buttons in a borderless window far off screen, and a popover to
/// open from them.
@MainActor
final class Stage {
    let window: NSWindow
    let button = MenuButton()
    let other = MenuButton()
    let popover = MenuPopover()

    init(appearance: NSAppearance? = nil) {
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        button.show("Menu", font: .systemFont(ofSize: 12), ink: .secondaryLabelColor)
        other.show("Other", font: .systemFont(ofSize: 12), ink: .secondaryLabelColor)
        button.frame = NSRect(origin: CGPoint(x: 150, y: 150), size: button.fittingSize)
        other.frame = NSRect(origin: CGPoint(x: 20, y: 20), size: other.fittingSize)
        window.contentView?.addSubview(button)
        window.contentView?.addSubview(other)
        window.orderFrontRegardless()
    }
}
