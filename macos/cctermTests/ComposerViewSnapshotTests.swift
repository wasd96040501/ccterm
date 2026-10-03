import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// The composer in every state the design's sheet specimens show
/// (`buildLiveSpecimens`), light and dark, at the transcript column's 720 pt
/// and at 380 — plus the slash list. Review only —
/// `make test-unit FILTER=ComposerViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/Composer-*.png` next to the design sheet.
@MainActor
final class ComposerViewSnapshotTests: XCTestCase {
    private typealias F = ComposerFixtures

    /// The composer pinned under a transcript-coloured page, with the 16-pt
    /// float the tab gives it; it takes the focus when it appears if asked.
    private final class Host: NSViewController {
        let composer = ComposerViewController()
        var text = ""
        var focused = false

        override func loadView() {
            let page = NSView()
            page.wantsLayer = true
            view = page
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(composer)
            composer.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(composer.view)
            NSLayoutConstraint.activate([
                composer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                composer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                composer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            ])
            composer.text = text
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            // A window hands the focus to its first field; only the specimen
            // that is focused keeps it.
            if focused { composer.focus() } else { view.window?.makeFirstResponder(nil) }
        }
    }

    private struct Specimen {
        var name: String
        var model: ComposerModel
        var text = ""
        var focused = false
    }

    /// The sheet's ten composers (`cs[]` in `buildLiveSpecimens`).
    private var specimens: [Specimen] {
        let sonnet = ModelChoice(account: F.subscription, value: "sonnet")
        return [
            Specimen(
                name: "Idle",
                model: F.model(
                    F.session(.idle), settings: F.settings("sonnet", effort: .xhigh, mode: .acceptEdits)),
                text: "Now run the snapshot tests", focused: true),
            Specimen(
                name: "Responding",
                model: F.model(
                    F.session(.responding), settings: F.settings("opus", effort: .high, mode: .auto),
                    pendingModel: sonnet),
                text: "Also update the docs"),
            Specimen(
                name: "Waiting",
                model: F.model(
                    F.session(.responding, waiting: true, visible: false),
                    settings: F.settings("opus", effort: .high, mode: .default))),
            Specimen(
                name: "Starting",
                model: F.model(
                    F.session(.starting), settings: F.settings("opus", effort: .high, mode: .auto))),
            Specimen(
                name: "AtRest",
                model: F.model(
                    F.session(.atRest), settings: F.settings("sonnet", effort: .xhigh, mode: .acceptEdits))),
            Specimen(
                name: "Failed",
                model: F.model(
                    F.session(
                        .failed(
                            SessionFailure(
                                reason: "Exit code 1", output: "API Error: 529 overloaded_error · retries exhausted")
                        )),
                    settings: F.settings("opus", effort: .high, mode: .auto))),
            Specimen(
                name: "HaikuBypass",
                model: F.model(
                    F.session(.idle), settings: F.settings("haiku", effort: .high, mode: .bypassPermissions),
                    allowsBypass: true)),
            Specimen(
                name: "FastRing",
                model: F.model(
                    F.session(.idle), settings: F.settings("opus", effort: .max, mode: .acceptEdits, fast: true),
                    usage: 0.72)),
            Specimen(
                name: "Refused",
                model: F.model(
                    F.session(.idle), settings: F.settings("opus", effort: .high, mode: .auto),
                    refusal: "Opus 4.8 isn’t available to your organization.")),
            Specimen(
                name: "Command",
                model: F.model(F.session(.idle), settings: F.settings("opus", effort: .high, mode: .auto)),
                text: "/review #327"),
            Specimen(
                name: "NewTab",
                model: F.model(.draft, settings: F.settings("default", on: F.relay, effort: .high, mode: .acceptEdits))),
            Specimen(
                name: "Loading",
                model: F.model(.draft, settings: nil, catalog: ModelCatalog())),
        ]
    }

    private func host(_ specimen: Specimen, width: CGFloat) -> Host {
        let host = Host()
        host.text = specimen.text
        host.focused = specimen.focused
        host.loadViewIfNeeded()
        host.composer.configure(with: specimen.model)
        // A completed command is the token; the field knows the catalog's names.
        host.composer.text = specimen.text
        return host
    }

    /// How tall the page must be: the card, the 16-pt float and some page above.
    private func height(of specimen: Specimen, width: CGFloat) -> CGFloat {
        let probe = host(specimen, width: width)
        probe.view.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        probe.view.layoutSubtreeIfNeeded()
        return ceil(probe.composer.fittedHeight) + 16 + 24
    }

    private func sheet(width: CGFloat) -> NSImage {
        let sheets = specimens.map { specimen -> NSImage in
            let height = height(of: specimen, width: width)
            return ViewSnapshot.renderLightAndDark(
                { self.host(specimen, width: width) }, size: CGSize(width: width, height: height), name: "")
        }
        return stack(sheets)
    }

    private func stack(_ sheets: [NSImage]) -> NSImage {
        let gap: CGFloat = 12
        let width = sheets.map(\.size.width).max() ?? 0
        let height = sheets.map(\.size.height).reduce(0, +) + gap * CGFloat(max(0, sheets.count - 1))
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        var y = height
        for sheet in sheets {
            y -= sheet.size.height
            sheet.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .copy, fraction: 1)
            y -= gap
        }
        image.unlockFocus()
        return image
    }

    private func attach(_ url: URL) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTheComposerInEveryStateAtTheTranscriptsWidth() {
        attach(ViewSnapshot.writePNG(sheet(width: 752), name: "Composer-720"))
    }

    func testTheComposerNarrow() {
        attach(ViewSnapshot.writePNG(sheet(width: 412), name: "Composer-380"))
    }

    func testTheComposerWhenCramped() {
        // Between the tiers: the provider's name gone; then the words gone.
        let specimen = specimens[10]
        let sheets = [592, 492].map { width -> NSImage in
            ViewSnapshot.renderLightAndDark(
                { self.host(specimen, width: CGFloat(width)) },
                size: CGSize(width: CGFloat(width), height: height(of: specimen, width: CGFloat(width))), name: "")
        }
        attach(ViewSnapshot.writePNG(stack(sheets), name: "Composer-Tiers"))
    }

    // MARK: - Against the design

    /// Each specimen beside the sheet's own composer of that state, at its
    /// width, as the window server composites it (`CompositedCapture`: the
    /// card's rings and shadows, and translucent ink at its true strength):
    /// `/tmp/ccterm-parity/<scheme>-part-<card>-comp0.png`. Needs the display
    /// awake; asleep, it skips.
    func testTheComposerAgainstTheDesign() async throws {
        let cards = [
            "Idle": "07", "Responding": "08", "Waiting": "09", "Starting": "10", "AtRest": "11", "Failed": "12",
            "HaikuBypass": "13", "FastRing": "14", "Refused": "15", "Command": "16",
        ]
        for scheme in DesignParity.Scheme.allCases {
            for specimen in specimens {
                guard let card = cards[specimen.name] else { continue }
                try await pair("part-\(card)-comp0", specimen, scheme)
            }
        }
    }

    /// *A 4-pt grid; words never cut*: a provider's model at rest at 492 pt,
    /// where the provider's name and the controls' words are gone, and at
    /// 330, where the status takes its own line under the controls.
    func testTheNarrowComposersAgainstTheDesign() async throws {
        let specimen = Specimen(
            name: "Narrow",
            model: F.model(
                F.session(.atRest), settings: F.settings("default", on: F.relay, effort: .high, mode: .acceptEdits)))
        for scheme in DesignParity.Scheme.allCases {
            try await pair("part-35-comp0", specimen, scheme)
            try await pair("part-35-comp1", specimen, scheme)
        }
    }

    /// The command list as the sheet's *Commands* specimen shows it, 420 pt
    /// wide, the first row under the keyboard.
    func testTheSlashListAgainstTheDesign() async throws {
        for scheme in DesignParity.Scheme.allCases {
            let id = "part-31-slash0"
            let part = try DesignParity.part(id, scheme)
            let list = SlashListViewController()
            list.configure(commands: F.commands, width: part.width)
            let host = PageHost(page: scheme.page, content: list)
            let image = try await CompositedCapture.render(
                host, size: CGSize(width: part.width, height: max(part.height, list.preferredSize.height)),
                appearance: scheme.appearance)
            attach(try DesignParity.write(id, scheme, ours: image))
        }
    }

    /// `content` at its own size, top-left, on the sheet's page.
    private final class PageHost: NSViewController {
        let page: NSColor
        let content: NSViewController

        init(page: NSColor, content: NSViewController) {
            self.page = page
            self.content = content
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func loadView() {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = page.cgColor
            self.view = view
            addChild(content)
            content.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(content.view)
            NSLayoutConstraint.activate([
                content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.view.topAnchor.constraint(equalTo: view.topAnchor),
            ])
        }
    }

    /// Writes design | ours | difference for `specimen` at part `id`'s width.
    private func pair(_ id: String, _ specimen: Specimen, _ scheme: DesignParity.Scheme) async throws {
        let part = try DesignParity.part(id, scheme)
        let probe = host(specimen, width: part.width)
        probe.view.frame = NSRect(x: 0, y: 0, width: part.width, height: 400)
        probe.view.layoutSubtreeIfNeeded()
        let height = max(part.height, ceil(probe.composer.fittedHeight))
        let image = try await CompositedCapture.render(
            flush(specimen, page: scheme.page), size: CGSize(width: part.width, height: height),
            appearance: scheme.appearance)
        attach(try DesignParity.write(id, scheme, ours: image))
    }

    /// The card alone, edge to edge, on the sheet's page — as the design's capture frames it.
    private func flush(_ specimen: Specimen, page: NSColor) -> NSViewController {
        let host = Flush(page: page)
        host.loadViewIfNeeded()
        host.composer.configure(with: specimen.model)
        host.composer.text = specimen.text
        host.focused = specimen.focused
        return host
    }

    private final class Flush: NSViewController {
        let composer = ComposerViewController()
        let page: NSColor
        var focused = false

        init(page: NSColor) {
            self.page = page
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func loadView() {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = page.cgColor
            self.view = view
            addChild(composer)
            composer.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(composer.view)
            NSLayoutConstraint.activate([
                composer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                composer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                composer.view.topAnchor.constraint(equalTo: view.topAnchor),
            ])
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            if focused { composer.focus() } else { view.window?.makeFirstResponder(nil) }
        }
    }

    func testTheSlashListOverTheCard() {
        let list = SlashListViewController()
        list.loadViewIfNeeded()
        list.configure(commands: F.commands, width: 720)
        let size = list.preferredSize
        let sheet = ViewSnapshot.renderLightAndDark(
            {
                let list = SlashListViewController()
                list.loadViewIfNeeded()
                list.configure(commands: F.commands, width: 720)
                return list
            }, size: size, name: "")
        attach(ViewSnapshot.writePNG(sheet, name: "Composer-SlashList"))
        XCTAssertGreaterThan(size.height, 100)
    }
}
