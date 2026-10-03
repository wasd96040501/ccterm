import AppKit
import Components
import DisplayModels
import TranscriptKit
import XCTest

@testable import ccterm

/// Renders a whole `TranscriptPage` the way a transcript tab shows it — the
/// transcript's own bubbles and markdown with the page's row views among them —
/// light above dark, to `/tmp/ccterm-screenshots/<name>.png`, for review. What
/// `RowSnapshot` is to one kind of `.view` row, this is to rows TranscriptKit
/// draws itself (a bubble with tokens) and to how rows sit together.
enum PageSnapshot {
    @MainActor
    static func render(
        _ page: TranscriptPage, widths: [CGFloat] = [560], height: CGFloat = 520,
        disclosure: RunDisclosure = .collapsed, name: String, test: XCTestCase,
        prepare: (Host) -> Void = { _ in }
    ) {
        var columns: [NSImage] = []
        for width in widths {
            let panels = [NSAppearance.Name.aqua, .darkAqua].map { appearance -> NSImage in
                let host = Host(page: page, disclosure: disclosure)
                host.loadView()
                host.view.appearance = NSAppearance(named: appearance)
                host.view.appearance?.performAsCurrentDrawingAppearance {
                    host.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                let size = CGSize(width: width, height: height)
                return ViewSnapshot.renderViewController(host, size: size) { prepare(host) }
            }
            let stacked = NSImage(size: NSSize(width: panels[0].size.width, height: panels[0].size.height * 2))
            stacked.lockFocus()
            panels[1].draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
            panels[0].draw(at: NSPoint(x: 0, y: panels[0].size.height), from: .zero, operation: .copy, fraction: 1)
            stacked.unlockFocus()
            columns.append(stacked)
        }
        let total = NSImage(
            size: NSSize(width: columns.map(\.size.width).reduce(0, +), height: columns.map(\.size.height).max() ?? 0))
        total.lockFocus()
        var x: CGFloat = 0
        for column in columns {
            column.draw(at: NSPoint(x: x, y: 0), from: .zero, operation: .copy, fraction: 1)
            x += column.size.width
        }
        total.unlockFocus()
        let url = ViewSnapshot.writePNG(total, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    /// A transcript over a fixed page: the data source and delegate of
    /// `TranscriptViewController`, without a session behind it.
    @MainActor
    final class Host: NSViewController, TranscriptViewDataSource, TranscriptViewDelegate, PageRowViewDelegate {
        let transcript = TranscriptView()
        private(set) var rows: [PageRow]
        /// The picture whose thumbnail is outlined.
        var highlightedImage: (entry: String, number: Int)?

        init(page: TranscriptPage, disclosure: RunDisclosure) {
            rows = page.entries.flatMap { PageRow.rows(for: $0, disclosure: disclosure) }
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override func loadView() {
            view = NSView()
            view.wantsLayer = true
            transcript.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(transcript)
            NSLayoutConstraint.activate([
                transcript.topAnchor.constraint(equalTo: view.topAnchor),
                transcript.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                transcript.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                transcript.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            transcript.maxContentWidth = 720
            transcript.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
            transcript.dataSource = self
            transcript.delegate = self
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            view.layoutSubtreeIfNeeded()
            transcript.reloadData()
        }

        func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

        func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
            rows[row].transcriptRow
        }

        func transcriptView(_ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
            rows[row].height(width: width)
        }

        func transcriptView(_ transcriptView: TranscriptView, customSpacingAboveRow row: Int) -> CGFloat? {
            rows[row].spacingAbove(after: row > 0 ? rows[row - 1] : nil)
        }

        func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
            let pageRow = rows[row]
            let highlighted = highlightedImage.flatMap { $0.entry == pageRow.id.entry ? $0.number : nil }
            return pageRow.makeView(
                in: transcriptView, isSelected: false, flashes: false, highlightedImage: highlighted, delegate: self)
        }

        func pageRowView(_ rowView: NSView, didRequestDocument id: String, pinned: Bool) {}
        func pageRowView(_ rowView: NSView, didToggleDisclosureOf runID: String, inAllRuns all: Bool) {}
        func pageRowView(_ rowView: NSView, didRequestAllItemsOf runID: String) {}
        func pageRowView(_ rowView: NSView, didRequestOriginOf callID: String) {}
        func pageRowView(_ rowView: NSView, didDecide decision: Decision, forCall callID: String) {}
    }
}
