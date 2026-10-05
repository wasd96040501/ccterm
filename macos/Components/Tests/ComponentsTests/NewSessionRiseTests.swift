import AppKit
import QuartzCore
import XCTest

@testable import Components

/// Send's rise in the New view (design 08 *Send is the one moment it moves*):
/// 600 ms, row onsets 0 / 70 / 150 / 240 / 340 ms, each a 240-ms flash to
/// 55 % white over the icon's cursor, the glow swelling on cubic-bezier(.2,.7,.2,1);
/// Reduce Motion: at once.
///
/// The definition of the animation and the completion run anywhere; the frame
/// sampling (`testTheRowsLightOnTheirOnsetsAsComposited`) needs the display awake.
@MainActor
final class NewSessionRiseTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    /// The view in a window parked off screen, as the app's tab holds it.
    private func mount(reduceMotion: Bool = false) -> NewSessionViewController {
        let controller = NewSessionViewController(prefersReducedMotion: { reduceMotion })
        let size = CGSize(width: 720, height: 560)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: container.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        self.window = window
        return controller
    }

    /// The layer named `name` under any view of the tree (the view itself
    /// need not be layer-backed; its backed descendants are).
    private func layer(named name: String, in root: NSView) -> CALayer? {
        func search(_ layer: CALayer) -> CALayer? {
            if layer.name == name { return layer }
            return (layer.sublayers ?? []).lazy.compactMap(search).first
        }
        if let found = root.layer.flatMap(search) { return found }
        return root.subviews.lazy.compactMap { self.layer(named: name, in: $0) }.first
    }

    private func rowLayers(_ controller: NewSessionViewController) throws -> [CALayer] {
        try (0..<NewSessionIconView.rowCount).map { k in
            try XCTUnwrap(layer(named: "rise-row-\(k)", in: controller.view), "row \(k)")
        }
    }

    func testTheOnsetsAreTheDesigns() {
        XCTAssertEqual(
            (0..<5).map { NewSessionIconView.onset(ofRow: $0) }, [0, 0.070, 0.150, 0.240, 0.340])
        XCTAssertEqual(NewSessionIconView.riseDuration, 0.6)
    }

    func testTheRowsSitOverTheCursorBottomToTop() throws {
        let controller = mount()
        let rows = try rowLayers(controller)
        // The icon is 64 pt; the cursor spans x 38…47 and y 26.75…41.75 from the top.
        for (k, row) in rows.enumerated() {
            XCTAssertEqual(row.frame.minX, 38, accuracy: 0.01)
            XCTAssertEqual(row.frame.width, 9, accuracy: 0.01)
            XCTAssertEqual(row.frame.height, 3, accuracy: 0.01)
            if k > 0 {
                XCTAssertEqual(row.frame.minY - rows[k - 1].frame.minY, 3, accuracy: 0.01, "row \(k) above \(k - 1)")
            }
            XCTAssertEqual(row.opacity, 0, "dark until its flash")
        }
    }

    func testRiseSchedulesEachRowsFlashAndTheGlowsSwell() throws {
        let controller = mount()
        let rows = try rowLayers(controller)
        let glow = try XCTUnwrap(layer(named: "glow", in: controller.view))
        let restOpacity = glow.opacity

        let start = CACurrentMediaTime()
        controller.rise {}

        for (k, row) in rows.enumerated() {
            let flash = try XCTUnwrap(row.animation(forKey: "flash") as? CAKeyframeAnimation, "row \(k)")
            XCTAssertEqual(flash.duration, 0.24, accuracy: 1e-6)
            XCTAssertEqual(flash.keyTimes?.map(\.doubleValue) ?? [], [0, 0.3, 1])
            XCTAssertEqual((flash.values as? [NSNumber])?.map(\.floatValue) ?? [], [0, 0.55, 0])
            let onset = row.convertTime(flash.beginTime, to: nil) - start
            XCTAssertEqual(onset, NewSessionIconView.onset(ofRow: k), accuracy: 0.05, "row \(k) onset")
        }

        let swell = try XCTUnwrap(glow.animation(forKey: "swell-opacity") as? CABasicAnimation)
        XCTAssertEqual(swell.duration, 0.6, accuracy: 1e-6)
        XCTAssertEqual(swell.fromValue as? Float, restOpacity)
        XCTAssertGreaterThan(glow.opacity, restOpacity, "the glow stays up at the end")
        let curve = try XCTUnwrap(glow.animation(forKey: "swell-transform"))
        var points = [Float](repeating: 0, count: 2)
        var control: [Float] = []
        for index in 1...2 {
            curve.timingFunction?.getControlPoint(at: index, values: &points)
            control += points
        }
        XCTAssertEqual(control, [0.2, 0.7, 0.2, 1])
    }

    func testTheRestingGlowIsSixtyPercentOfFull() throws {
        let controller = mount()
        controller.view.appearance = NSAppearance(named: .aqua)
        let glow = try XCTUnwrap(layer(named: "glow", in: controller.view))
        XCTAssertEqual(glow.opacity, 0.42 * 0.6, accuracy: 0.001)

        controller.view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(glow.opacity, 0.36 * 0.6, accuracy: 0.001, "42 % becomes 36 % in Dark")
    }

    func testCompletionComesWhenTheRiseEnds() {
        let controller = mount()
        let done = expectation(description: "rise ended")
        let start = CACurrentMediaTime()
        var elapsed: TimeInterval = 0
        controller.rise {
            elapsed = CACurrentMediaTime() - start
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertGreaterThanOrEqual(elapsed, 0.59)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testAnotherSendDuringTheRiseJoinsIt() {
        let controller = mount()
        let both = expectation(description: "both completions")
        both.expectedFulfillmentCount = 2
        controller.rise { both.fulfill() }
        controller.rise { both.fulfill() }
        wait(for: [both], timeout: 3)
    }

    func testReduceMotionHandsOverAtOnce() throws {
        let controller = mount(reduceMotion: true)
        var called = false
        controller.rise { called = true }
        XCTAssertTrue(called, "completion is synchronous")
        for row in try rowLayers(controller) { XCTAssertNil(row.animation(forKey: "flash")) }
    }

    func testSettlingTheRiseEndsItAtOnceWithoutItsCompletion() throws {
        let controller = mount()
        let rows = try rowLayers(controller)
        let glow = try XCTUnwrap(layer(named: "glow", in: controller.view))
        let restOpacity = glow.opacity
        var completed = false
        controller.rise { completed = true }
        XCTAssertNotNil(rows[0].animation(forKey: "flash"))

        controller.settleRise()

        for row in rows { XCTAssertNil(row.animation(forKey: "flash")) }
        XCTAssertNil(glow.animation(forKey: "swell-opacity"))
        XCTAssertNil(glow.animation(forKey: "swell-transform"))
        XCTAssertEqual(glow.opacity, restOpacity, accuracy: 0.001)
        XCTAssertTrue(CATransform3DIsIdentity(glow.transform))

        // Past the rise's end: its completion never comes.
        let later = expectation(description: "past the rise")
        DispatchQueue.main.asyncAfter(deadline: .now() + NewSessionIconView.riseDuration + 0.2) { later.fulfill() }
        wait(for: [later], timeout: 3)
        XCTAssertFalse(completed)
    }

    func testARiseAfterASettledOneStillCompletes() {
        let controller = mount()
        controller.rise {}
        controller.settleRise()
        let done = expectation(description: "second rise ended")
        controller.rise { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    // MARK: - Needs the display awake

    /// Samples the rows' presentation opacity per frame and checks each lights
    /// at its onset and is out 240 ms later, and that the completion lands at 600 ms.
    func testTheRowsLightOnTheirOnsetsAsComposited() throws {
        let controller = mount()
        let rows = try rowLayers(controller)
        var samples: [(t: Double, opacity: [Float])] = []
        let start = CACurrentMediaTime()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
            samples.append((CACurrentMediaTime() - start, rows.map { $0.presentation()?.opacity ?? -1 }))
        }
        let done = expectation(description: "rise ended")
        controller.rise { done.fulfill() }
        wait(for: [done], timeout: 3)
        timer.invalidate()

        func peak(row k: Int, from: Double, to: Double) -> Float {
            samples.filter { $0.t >= from && $0.t <= to }.map { $0.opacity[k] }.max() ?? -1
        }
        for k in 0..<5 {
            let onset = NewSessionIconView.onset(ofRow: k)
            XCTAssertLessThan(peak(row: k, from: 0, to: onset - 0.03), 0.02, "row \(k) dark before its onset")
            XCTAssertEqual(
                peak(row: k, from: onset, to: onset + 0.24), 0.55, accuracy: 0.12, "row \(k) flashes to 55 %")
            XCTAssertLessThan(peak(row: k, from: onset + 0.30, to: 0.6), 0.02, "row \(k) is out after its flash")
        }
    }
}
