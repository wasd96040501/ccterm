import AgentSDK
import AppKit
import Combine
import Components
import DisplayModels
import XCTest

@testable import ccterm

/// The New view and the branch popover, light above dark, at the design's
/// widths — for a human to look at against `design/transcript` (08 *The New
/// view*). Run by name: `make test-unit FILTER=NewSessionViewControllerSnapshotTests`.
@MainActor
final class NewSessionViewControllerSnapshotTests: XCTestCase {
    private let folder = URL(fileURLWithPath: NSHomeDirectory() + "/dev/ccterm")
    private let settings = SessionSettings(
        model: .default(on: UUID()), effort: nil, permissionMode: .default, fastMode: false)

    private var repository: RepositoryState {
        RepositoryState(
            root: folder, branch: "main",
            localBranches: [
                "main", "live-session-design", "fix-gutter-overflow", "exactlist-bench", "settings-accounts",
            ],
            remoteBranches: ["origin/release/1.4", "origin/sidebar-icons"],
            branchesCheckedOutElsewhere: ["live-session-design"],
            hasUncommittedChanges: false, defaultBranch: "main")
    }

    private func draft(_ edit: (inout NewSessionDraft) -> Void = { _ in }) -> NewSessionDraft {
        var draft = NewSessionDraft(folder: folder, settings: settings)
        edit(&draft)
        return draft
    }

    /// The window's own background, so Dark renders on a dark page.
    private static func addWindowBackground(to view: NSView) {
        let background = WindowBackgroundView()
        background.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(background, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func makeController(_ model: NewSessionModel) -> NewSessionViewController {
        let controller = NewSessionViewController()
        controller.loadViewIfNeeded()
        controller.configure(with: NewSessionContent(model))
        // Stands in for the composer: a card in the slot.
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        Self.addWindowBackground(to: controller.view)
        controller.view.addSubview(card)
        NSLayoutConstraint.activate([
            controller.composerGuide.heightAnchor.constraint(equalToConstant: 96),
            card.leadingAnchor.constraint(equalTo: controller.composerGuide.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: controller.composerGuide.trailingAnchor),
            card.topAnchor.constraint(equalTo: controller.composerGuide.topAnchor),
            card.bottomAnchor.constraint(equalTo: controller.composerGuide.bottomAnchor),
        ])
        return controller
    }

    private func sheet(_ model: NewSessionModel, size: CGSize) -> NSImage {
        ViewSnapshot.renderLightAndDark({ [self] in makeController(model) }, size: size, name: "NewSession")
    }

    private func model(
        _ draft: NewSessionDraft, repository: NewSessionModel.Repository? = nil
    ) -> NewSessionModel {
        NewSessionModel(
            draft: draft, repository: repository ?? .repository(self.repository),
            recentFolders: [folder, URL(fileURLWithPath: NSHomeDirectory() + "/dev/ghostty")])
    }

    func testStates() {
        let wide = CGSize(width: 720, height: 560)
        let narrow = CGSize(width: 380, height: 560)
        var sheets: [NSImage] = []
        let rest = model(draft())
        sheets.append(sheet(rest, size: wide))
        sheets.append(sheet(rest, size: narrow))
        sheets.append(
            sheet(model(draft { $0.choose(branch: .named("fix-gutter-overflow"), in: repository) }), size: wide))
        sheets.append(sheet(model(draft { $0.toggleWorktree(in: repository) }), size: wide))
        sheets.append(sheet(model(draft { $0.choose(branch: .pullRequest(327), in: repository) }), size: wide))
        sheets.append(sheet(model(draft(), repository: .notARepository), size: wide))
        let url = ViewSnapshot.writeStack(sheets, name: "NewSessionView")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Against the design

    /// The New view as the design sheet's specimens draw it (cards 02–04): the
    /// real view with the real composer in its slot, beside the sheet's —
    /// `/tmp/ccterm-parity/<scheme>-part-0N-new0.png`. A specimen is static:
    /// 28 pt above the icon and 8 at the sides, where a tab centres the view
    /// optically and keeps 24 at the sides. So ours is laid out 32 pt wider
    /// (its composer then has the specimen's width) and as tall as puts 28 pt
    /// above the icon, and cropped to the specimen. Needs the display awake.
    func testTheNewViewAgainstTheDesign() async throws {
        let relayDraft = draft {
            $0.settings = ComposerFixtures.settings("default", on: ComposerFixtures.relay, mode: .acceptEdits)
            $0.toggleWorktree(in: repository)
        }
        let notes = URL(fileURLWithPath: NSHomeDirectory() + "/notes/claude-notes")
        let parts: [(id: String, model: NewSessionModel, composer: SessionSettings)] = [
            ("part-02-new0", model(draft()), ComposerFixtures.settings()),
            ("part-03-new0", model(relayDraft), relayDraft.settings),
            (
                "part-04-new0",
                NewSessionModel(
                    draft: NewSessionDraft(folder: notes, settings: settings), repository: .notARepository,
                    recentFolders: []),
                ComposerFixtures.settings()
            ),
        ]
        for scheme in DesignParity.Scheme.allCases {
            NSApp.appearance = scheme.appearance
            defer { NSApp.appearance = nil }
            for part in parts {
                let design = try DesignParity.part(part.id, scheme)
                let make = {
                    ParityHost(
                        model: part.model, composer: ComposerFixtures.model(.draft, settings: part.composer),
                        page: scheme.page)
                }
                let width = design.width + 32
                let height = Self.height(placingIconAt: 28, width: width, make)
                // Composited, as the screen shows it: `cacheDisplay` draws translucent words too dark.
                let image = try await CompositedCapture.render(
                    make(), size: CGSize(width: width, height: height), appearance: scheme.appearance)
                let cropped = Self.crop(image, to: NSRect(x: 16, y: 0, width: design.width, height: design.height))
                let url = try DesignParity.write(part.id, scheme, ours: cropped)
                let attachment = XCTAttachment(contentsOfFile: url)
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    /// A real New tab — the session tab in its draft, with its composer — at
    /// the pane the sheet's *New tab* scene gives it (900 × 642, under the
    /// title bar and the tab bar), composited: `/tmp/ccterm-parity/<scheme>-
    /// scene-new-pane.png`, to measure against `<scheme>-scene-new.png`'s pane
    /// (x 228, y 78 pt).
    func testTheNewTabAtTheScenesPane() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("ccterm")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let suite = "ccterm-tests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let context = TranscriptTab.Context(
            sessions: .reading(), catalog: Just(ComposerFixtures.catalog).eraseToAnyPublisher(),
            preferences: Just(LaunchPreferences()).eraseToAnyPublisher(),
            defaults: NewSessionDefaults(defaults: UserDefaults(suiteName: suite)!), branches: BranchService(),
            recentFolders: Just([]).eraseToAnyPublisher())
        for scheme in DesignParity.Scheme.allCases {
            let tab = SessionTabViewController(
                .draft(folder: folder, text: ""), title: SessionTabTitle.draft, context: context)
            let image = try await CompositedCapture.render(
                tab, size: CGSize(width: 900, height: 642), appearance: scheme.appearance, settle: 1)
            let url = DesignParity.directory.appendingPathComponent("\(scheme.rawValue)-scene-new-pane.png")
            try FileManager.default.createDirectory(at: DesignParity.directory, withIntermediateDirectories: true)
            let rep = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            try XCTUnwrap(NSBitmapImageRep(cgImage: rep).representation(using: .png, properties: [:])).write(to: url)
        }
    }

    /// The height at which the optical centring leaves `top` above the icon:
    /// the free space splits 0.62 : 1 above and below the content.
    private static func height(placingIconAt top: CGFloat, width: CGFloat, _ make: () -> ParityHost) -> CGFloat {
        let probe = make()
        probe.view.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        probe.view.layoutSubtreeIfNeeded()
        let above = 1000 - probe.iconFrame.maxY
        let content = 1000 - above - above / 0.62
        return (content + top + top / 0.62).rounded()
    }

    /// `rect` of `image`, from its top-left.
    private static func crop(_ image: NSImage, to rect: NSRect) -> NSImage {
        let cropped = NSImage(size: rect.size)
        cropped.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: rect.size),
            from: NSRect(
                x: rect.minX, y: image.size.height - rect.maxY, width: rect.width, height: rect.height),
            operation: .copy, fraction: 1)
        cropped.unlockFocus()
        return cropped
    }

    func testBranchPopover() {
        let list: NewSessionModel.BranchList = {
            guard case .repository(_, _, let list) = model(draft()).branchRow else {
                return .init(local: [], remote: [])
            }
            return list
        }()
        var sheets: [NSImage] = []
        for query in ["", "#327"] {
            let content = NewSessionMenu.branchContent(of: list, query: query)
            let probe = MenuPanelViewController()
            probe.configure(with: content)
            sheets.append(
                ViewSnapshot.renderLightAndDark(
                    {
                        let controller = MenuPanelViewController()
                        controller.configure(with: content)
                        return controller
                    }, size: probe.preferredSize, name: "BranchPicker"))
        }
        let url = ViewSnapshot.writeStack(sheets, name: "NewSessionBranchPicker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

/// The New view with the real composer in its slot, as `SessionTabViewController`
/// mounts a draft (`mountDraft`), on the sheet's page.
@MainActor
private final class ParityHost: NSViewController {
    private let newSession = NewSessionViewController()
    private let composer = ComposerViewController()
    private let model: NewSessionModel
    private let composerModel: ComposerPresentation
    private let page: NSColor

    init(model: NewSessionModel, composer: ComposerPresentation, page: NSColor) {
        self.model = model
        composerModel = composer
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The icon's frame in this view (y up).
    var iconFrame: NSRect {
        let icon = newSession.view.subviews.first ?? newSession.view
        return icon.convert(icon.bounds, to: view)
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = page.cgColor
        view = root
        addChild(newSession)
        addChild(composer)
        let content = newSession.view
        content.translatesAutoresizingMaskIntoConstraints = false
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        root.addSubview(composer.view)
        let guide = newSession.composerGuide
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            composer.view.topAnchor.constraint(equalTo: guide.topAnchor),
            composer.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            guide.heightAnchor.constraint(equalTo: composer.view.heightAnchor),
        ])
        newSession.configure(with: NewSessionContent(model))
        composer.configure(with: composerModel)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }
}

@MainActor
private final class WindowBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}
