import AppKit
import SwiftUI

/// SwiftUI entry point. Mounts `Transcript2ScrollView` (containing a
/// `NSTableView` driven by `Transcript2Coordinator`) and binds the user
/// bubble's "show full message" sheet.
///
/// The view takes a caller-owned `Transcript2Controller` — there is no
/// `[Block]` `State` parameter. Callers mutate transcript content
/// imperatively via `controller.apply(.insert / .remove / .update)` for
/// incremental changes, or `controller.setHistory(_:)` for the cold-load
/// path. SwiftUI's role is reduced to mounting the AppKit view, wiring
/// the existing coordinator into it, and presenting the sheet driven by
/// `controller.pendingUserBubbleSheet`; `updateNSView` is a no-op.
struct NativeTranscript2View: View {
    @Bindable var controller: Transcript2Controller
    /// Async syntax highlighter, sourced from the SwiftUI environment so
    /// every host (chat, demo, stress) gets the same shared engine
    /// without explicit plumbing. `nil` is the legitimate "no host
    /// engine" mode — code blocks then render plain. Late-binds via
    /// `controller.attachSyntaxEngine` once `body` resolves the env.
    @Environment(\.syntaxEngine) private var syntaxEngine

    var body: some View {
        Transcript2NSViewBridge(controller: controller)
            // Paint the SwiftUI-rendered `windowBackgroundColor` behind the
            // transparent NSScrollView/NSTableView. In dark mode AppKit's
            // direct `windowBackgroundColor` paint and SwiftUI's
            // `Color(nsColor:)` render produce slightly different RGB after
            // color-space conversion — without this, the transcript area
            // (showing NSWindow's paint through) reads a few shades off the
            // surrounding `FadeScrim` (SwiftUI-painted).
            .background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $controller.pendingUserBubbleSheet) { request in
                UserBubbleSheetView(text: request.text)
            }
            .sheet(item: $controller.pendingImagePreview) { request in
                ImagePreviewSheetView(image: request.image)
            }
            .task(id: ObjectIdentifier(controller)) {
                // Idempotent re-attach. Survives `controller` swap (rare,
                // but `.task(id:)` makes the dependency explicit) and
                // engine swap (env updates don't normally happen, but the
                // controller's `attachSyntaxEngine` handles a re-set
                // gracefully via the per-block generation guard).
                controller.attachSyntaxEngine(syntaxEngine)
            }
    }
}

/// Modal preview for a tapped attachment chip. Aspect-fit the original
/// `NSImage` inside a generously-sized window; click anywhere to
/// dismiss (matches the Quick Look-style "tap to close" muscle memory
/// users have for image previews on macOS). Escape and the default
/// action key (Return) also close — covered by the SwiftUI button.
struct ImagePreviewSheetView: View {
    let image: NSImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // The image surface itself is the primary dismiss target —
            // tapping the picture or the surrounding inset both close
            // the sheet without grabbing focus. `.contentShape` on the
            // ZStack ensures the empty padding catches hits too.
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
            }
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(
            minWidth: 480, idealWidth: 880, maxWidth: 1400,
            minHeight: 360, idealHeight: 660, maxHeight: 1050)
    }
}

/// Modal view for a user bubble's full text. Selection / copy come for
/// free via `Text.textSelection(.enabled)`; the dismiss button lives in
/// the bottom-right and binds the default action key (Return).
struct UserBubbleSheetView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(
            minWidth: 520, idealWidth: 720, maxWidth: 960,
            minHeight: 360, idealHeight: 540, maxHeight: 800)
    }
}

/// `NSViewRepresentable` half — kept private so the SwiftUI-side sheet
/// modifier composes cleanly above it.
private struct Transcript2NSViewBridge: NSViewRepresentable {
    let controller: Transcript2Controller

    func makeCoordinator() -> Transcript2Coordinator { controller.coordinator }

    func makeNSView(context: Context) -> Transcript2ScrollView {
        // AppKit setup is shared with the AppKit-rooted host
        // (`TranscriptDetailViewController`) via the factory below.
        // SwiftUI's NSViewRepresentable contract gives us no hook
        // between makeNSView and the first layout pass, so we bind
        // immediately. The host-driven defer pattern (see
        // `TranscriptDetailViewController.attachSession`) is only
        // available to AppKit-rooted callers; preview / demo paths
        // pay the small pre-layout typeset cost.
        let scroll = TranscriptScrollViewFactory.make(controller: controller)
        TranscriptScrollViewFactory.bindData(scroll, controller: controller)
        return scroll
    }

    func updateNSView(_ nsView: Transcript2ScrollView, context: Context) {
        // No-op. Content is pushed via `controller.apply(_:)`, not pulled
        // from a SwiftUI snapshot.
    }

    static func dismantleNSView(
        _ nsView: Transcript2ScrollView,
        coordinator: Transcript2Coordinator
    ) {
        // Symmetric teardown — removes the frameDidChange observer
        // and breaks the coordinator's weak ref so re-attach paths
        // see a fresh table.
        NotificationCenter.default.removeObserver(coordinator)
        if coordinator.tableView === (nsView.documentView as? NSTableView) {
            coordinator.tableView = nil
        }
    }
}

// MARK: - Preview

/// Generated once at module load — keeps `Block.id`s and `NSImage` instance
/// stable across Preview re-renders.
private let previewBlocks: [Block] = {
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
    let demoImage =
        NSImage(
            systemSymbolName: "photo.on.rectangle.angled",
            accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig)
        ?? NSImage(size: NSSize(width: 200, height: 120))
    let longUserText = (0..<18).map { "line \($0): some user text that wraps once or twice depending on width." }
        .joined(separator: "\n")
    return [
        Block(id: UUID(), kind: .userBubble(text: "Hi! Can you walk me through the refactor plan?")),
        Block(id: UUID(), kind: .userBubble(text: longUserText)),
        Block(id: UUID(), kind: .heading(level: 1, inlines: [.text("Refactor plan")])),
        Block(
            id: UUID(),
            kind: .paragraph(inlines: [
                .text("Replace the existing "),
                .code("NativeTranscript"),
                .text(" module with a smaller, "),
                .strong([.text("Core Text")]),
                .text("–based renderer."),
            ])),
        Block(id: UUID(), kind: .heading(level: 2, inlines: [.text("Layouts so far")])),
        Block(
            id: UUID(),
            kind: .paragraph(inlines: [
                .strong([.text("TextLayout")]),
                .text(" handles headings and paragraphs. "),
                .strong([.text("ImageLayout")]),
                .text(" handles raster / vector images. Both report their own height and draw themselves through the "),
                .code("RowLayout"),
                .text(" enum."),
            ])),
        Block(id: UUID(), kind: .image(demoImage)),
        Block(
            id: UUID(),
            kind: .paragraph(inlines: [
                .emphasis([.text("Adding a new block kind")]),
                .text(" means: extend "),
                .code("Block.Kind"),
                .text(", add a "),
                .code("XxxLayout"),
                .text(" primitive, add a case to "),
                .code("RowLayout"),
                .text(", add a switch arm in "),
                .code("Transcript2Coordinator.makeLayout"),
                .text("."),
            ])),
        Block(id: UUID(), kind: .heading(level: 2, inlines: [.text("List sample")])),
        Block(
            id: UUID(),
            kind: .list(
                ListBlock(
                    ordered: false,
                    items: [
                        ListBlock.Item(content: [
                            .paragraph([
                                .text("Bullet item with "),
                                .strong([.text("emphasis")]),
                                .text(" and "),
                                .code("inline code"),
                                .text("."),
                            ])
                        ]),
                        ListBlock.Item(content: [
                            .paragraph([.text("Nested list inside a bullet:")]),
                            .list(
                                ListBlock(
                                    ordered: true,
                                    items: [
                                        ListBlock.Item(content: [.paragraph([.text("Ordered child A")])]),
                                        ListBlock.Item(content: [.paragraph([.text("Ordered child B")])]),
                                    ])),
                        ]),
                        ListBlock.Item(
                            checkbox: true,
                            content: [
                                .paragraph([.text("Task done")])
                            ]),
                        ListBlock.Item(
                            checkbox: false,
                            content: [
                                .paragraph([.text("Task open")])
                            ]),
                    ]))),
        Block(id: UUID(), kind: .heading(level: 2, inlines: [.text("Table sample")])),
        Block(
            id: UUID(),
            kind: .table(
                TableBlock(
                    header: [
                        [.text("Block")], [.text("Layout")], [.text("Notes")],
                    ],
                    rows: [
                        [
                            [.text("paragraph")],
                            [.text("TextLayout")],
                            [.text("inline IR — bold / italic / code / link")],
                        ],
                        [
                            [.text("list")],
                            [.text("ListLayout")],
                            [.text("recursive items, marker midY-aligned to first content line")],
                        ],
                        [
                            [.text("table")],
                            [.text("TableLayout")],
                            [.text("CSS-like min/max column allocation; header bold; zebra body rows")],
                        ],
                    ],
                    alignments: [.left, .left, .left]))),
    ]
}()

private struct PreviewWrapper: View {
    @State private var controller = Transcript2Controller()

    var body: some View {
        NativeTranscript2View(controller: controller)
            .task {
                if controller.blockCount == 0 {
                    controller.setHistory(previewBlocks)
                }
            }
    }
}

#Preview("NativeTranscript2 — heading + paragraph + image") {
    PreviewWrapper()
        .frame(width: 600, height: 600)
        .environment(\.syntaxEngine, SyntaxHighlightEngine())
}
