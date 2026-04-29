import AppKit
import SwiftUI

/// Sandbox tab for stress-testing `NativeTranscript2` against ~1000 paragraphs
/// (~3 MB / ~800K tokens) of real prose. Used to exercise live-resize cost,
/// the lazy layout cache under high row counts, and the post-resize
/// background prefetch's anchor compensation under a long document.
///
/// Corpus is bundled as `transcript_stress_corpus.txt` (built by
/// `macos/scripts/build-stress-corpus.py`). Loading + parsing happens on a
/// background task; `controller.loadInitial(...)` then drives a viewport-
/// first sync insert + off-main layout for the rest, which is itself part
/// of the workload we're measuring.
struct TranscriptStressView: View {
    @State private var controller = Transcript2Controller()
    @State private var loadStatus: LoadStatus = .loading

    enum LoadStatus: Equatable {
        case loading
        case ready(blockCount: Int, charCount: Int)
        case missing
    }

    var body: some View {
        ZStack {
            NativeTranscript2View(controller: controller)
                .frame(minWidth: 320, minHeight: 240)

            if controller.blockCount == 0 {
                placeholder
            }
        }
        .overlay(alignment: .bottom) { statusBar }
        .task(id: "load") { await loadIfNeeded() }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch loadStatus {
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

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "speedometer")
                .foregroundStyle(.secondary)
            switch loadStatus {
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
        .padding(.bottom, 20)
    }

    private func loadIfNeeded() async {
        guard controller.blockCount == 0, case .loading = loadStatus else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadCorpus()
        }.value
        guard let loaded else {
            loadStatus = .missing
            return
        }
        let chars = loaded.reduce(0) { acc, b in
            switch b.kind {
            case .heading(_, let inlines), .paragraph(let inlines):
                return acc + InlineNode.charCount(inlines)
            case .image, .list, .table, .codeBlock, .blockquote,
                 .thematicBreak, .userBubble:
                // Stress corpus only emits heading / paragraph today, so
                // these cases are unreachable in practice. Listed for
                // exhaustiveness; if any of these ever land in the
                // corpus, swap this for a recursive char counter.
                return acc
            }
        }
        controller.loadInitial(loaded)
        loadStatus = .ready(blockCount: loaded.count, charCount: chars)
    }

    /// Pure: parses the bundled TSV corpus into `[Block]`. Returns `nil` if
    /// the resource is missing (e.g. fresh checkout before the script ran).
    nonisolated private static func loadCorpus() -> [Block]? {
        guard let url = Bundle.main.url(
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

#Preview {
    TranscriptStressView()
        .frame(width: 720, height: 720)
}
