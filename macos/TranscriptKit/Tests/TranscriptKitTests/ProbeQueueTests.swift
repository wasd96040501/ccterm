import AppKit
import XCTest

// PROBE (temporary): what AppKit's queue does to a posted mouse event, on CI.
@MainActor
final class ProbeQueueTests: XCTestCase {

    private func bounds(_ window: NSWindow) -> String {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber))
        guard let d = (info as? [[String: Any]])?.first?[kCGWindowBounds as String] as? [String: Any] else {
            return "none"
        }
        return "(\(d["X"] ?? "?"), \(d["Y"] ?? "?"), \(d["Width"] ?? "?"), \(d["Height"] ?? "?"))"
    }

    func testPROBE() {
        var bad = [0, 0, 0]
        for i in 0..<300 {
            let variant = i / 100
            let window = TestWindow.make(contentSize: NSSize(width: 400, height: 432))
            if variant == 1 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0)) }
            if variant == 2 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
            let serverBefore = bounds(window)
            let posted = NSEvent.mouseEvent(
                with: .leftMouseDragged, location: NSPoint(x: 5000, y: 300), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.postEvent(posted, atStart: false)
            let got = NSApp.nextEvent(
                matching: .leftMouseDragged, until: .distantPast, inMode: .default, dequeue: true)
            let location = got?.locationInWindow ?? .zero
            if location != NSPoint(x: 5000, y: 300) {
                bad[variant] += 1
                print(
                    "PROBEBAD i=\(i) variant=\(variant) got=\(location) cg=\(got?.cgEvent?.location ?? .zero) "
                        + "frame=\(window.frame) serverBefore=\(serverBefore) serverAfter=\(bounds(window)) "
                        + "win=\(got?.window === window)")
            }
            window.close()
        }
        print("PROBESUMMARY bad per variant (immediate, one turn, 0.1s): \(bad)")
    }
}
