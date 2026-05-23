import AppKit
import SwiftUI

/// AppKit-rooted host for the long-document stress demo. Replaces the
/// former SwiftUI `TranscriptStressView`. Loads ~1000 paragraphs from
/// the bundled `transcript_stress_corpus.txt`, then calls
/// `controller.setHistory(...)` which exercises the viewport-first
/// Phase 1 + off-main Phase 2 path. Mount + bottom status bar follow
/// the same pattern as `TranscriptDemoViewController`.
@MainActor
final class TranscriptStressViewController: NSViewController {

    init(syntaxEngine: SyntaxHighlightEngine? = nil) {
        self.syntaxEngine = syntaxEngine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    enum LoadStatus: Equatable {
        case loading
        case ready(blockCount: Int, charCount: Int)
        case missing
    }

    let controller = Transcript2Controller()
    private let syntaxEngine: SyntaxHighlightEngine?
    private var scroll: Transcript2ScrollView?
    private var sheetPresenter: Transcript2SheetPresenter?
    private var statusBarHost: NSHostingView<TranscriptStressStatusBar>?
    private var placeholderHost: NSHostingView<TranscriptStressPlaceholder>?
    private var statusModel = TranscriptStressStatusModel()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        mountTranscript()
        installStatusBar()
        installPlaceholder()
        sheetPresenter = Transcript2SheetPresenter(controller: controller, hostView: view)
        if let syntaxEngine {
            controller.attachSyntaxEngine(syntaxEngine)
        }
        Task { await loadIfNeeded() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        sheetPresenter?.stop()
    }

    private func mountTranscript() {
        let scroll = TranscriptScrollViewFactory.make(controller: controller)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.layoutSubtreeIfNeeded()
        TranscriptScrollViewFactory.bindData(scroll, controller: controller)
        controller.scrollToTail()
        self.scroll = scroll
    }

    private func installStatusBar() {
        let bar = TranscriptStressStatusBar(model: statusModel)
        let host = NSHostingView(rootView: bar)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
        statusBarHost = host
    }

    private func installPlaceholder() {
        let placeholder = TranscriptStressPlaceholder(model: statusModel)
        let host = NSHostingView(rootView: placeholder)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host, positioned: .below, relativeTo: statusBarHost)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        placeholderHost = host
    }

    private func loadIfNeeded() async {
        guard controller.blockCount == 0, statusModel.status == .loading else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadCorpus()
        }.value
        guard let loaded else {
            statusModel.status = .missing
            return
        }
        let chars = loaded.reduce(0) { acc, b in
            switch b.kind {
            case .heading(_, let inlines), .paragraph(let inlines):
                return acc + InlineNode.charCount(inlines)
            case .image, .userAttachments, .list, .table, .codeBlock, .blockquote,
                .thematicBreak, .userBubble, .toolGroup, .loadingPill:
                // Stress corpus only emits heading / paragraph today, so
                // these cases are unreachable in practice. Listed for
                // exhaustiveness; if any of these ever land in the
                // corpus, swap this for a recursive char counter.
                return acc
            }
        }
        controller.setHistory(loaded)
        statusModel.status = .ready(blockCount: loaded.count, charCount: chars)
    }

    /// Pure: parses the bundled TSV corpus into `[Block]`. Returns
    /// `nil` if the resource is missing (e.g. fresh checkout before
    /// the script ran).
    nonisolated private static func loadCorpus() -> [Block]? {
        guard
            let url = Bundle.main.url(
                forResource: "transcript_stress_corpus", withExtension: "txt")
        else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        var out: [Block] = []
        out.reserveCapacity(2000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let kindRaw = line[..<tab]
            let body = String(line[line.index(after: tab)...])
            let kind: Block.Kind
            switch kindRaw {
            case "H": kind = .heading(level: 1, inlines: [.text(body)])
            case "P": kind = .paragraph(inlines: [.text(body)])
            default: continue
            }
            out.append(Block(id: UUID(), kind: kind))
        }
        return out
    }
}

// MARK: - SwiftUI helpers

@Observable
@MainActor
final class TranscriptStressStatusModel {
    var status: TranscriptStressViewController.LoadStatus = .loading
}

struct TranscriptStressStatusBar: View {
    @Bindable var model: TranscriptStressStatusModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speedometer")
                .foregroundStyle(.secondary)
            switch model.status {
            case .loading:
                Text("Loading…").foregroundStyle(.secondary)
            case .missing:
                Text("Corpus missing").foregroundStyle(.red)
            case .ready(let n, let chars):
                Text("\(n) blocks · \(chars / 1024) KB")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}

struct TranscriptStressPlaceholder: View {
    @Bindable var model: TranscriptStressStatusModel

    var body: some View {
        switch model.status {
        case .loading:
            ProgressView("Loading stress corpus…")
                .controlSize(.large)
        case .missing:
            VStack(spacing: 6) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Corpus missing")
                    .font(.headline)
                Text("Run `macos/scripts/build-stress-corpus.py` and rebuild.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        case .ready:
            EmptyView()
        }
    }
}
