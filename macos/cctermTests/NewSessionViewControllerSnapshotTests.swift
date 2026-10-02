import AgentSDK
import AppKit
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

    private func makeController(_ model: NewSessionModel, hintsVisible: Bool = true) -> NewSessionViewController {
        let controller = NewSessionViewController()
        controller.loadViewIfNeeded()
        controller.configure(with: model)
        controller.setHintsVisible(hintsVisible)
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

    private func sheet(_ model: NewSessionModel, size: CGSize, hintsVisible: Bool = true) -> NSImage {
        ViewSnapshot.renderLightAndDark(
            { [self] in makeController(model, hintsVisible: hintsVisible) }, size: size, name: "NewSession")
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
        sheets.append(sheet(model(draft(), repository: .notARepository), size: wide, hintsVisible: false))
        let url = ViewSnapshot.writeStack(sheets, name: "NewSessionView")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
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
            sheets.append(
                ViewSnapshot.renderLightAndDark(
                    {
                        let controller = BranchPickerViewController(model: BranchPickerModel(list))
                        controller.loadViewIfNeeded()
                        Self.addWindowBackground(to: controller.view)
                        controller.view.layoutSubtreeIfNeeded()
                        controller.query = query
                        return controller
                    }, size: CGSize(width: 300, height: 300), name: "BranchPicker"))
        }
        let url = ViewSnapshot.writeStack(sheets, name: "NewSessionBranchPicker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
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
