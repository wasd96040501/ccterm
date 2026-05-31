import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// V2 input bar (UI only, no session handle wiring).
///
/// Layout: `HStack(attach, pill)` where `pill` is a squircle container that
/// wraps either `HStack(text, sendButton)` (idle) or
/// `VStack(thumbnailStrip, Divider, HStack(text, sendButton))` (one or more
/// attachments). Sizes are 20% smaller than the previous 40pt design, all
/// on a 4pt grid:
///
/// - pill: 32pt min height, `cornerRadius = 16`. Send button is concentric
///   with the bottom-right corner: button radius 12, shared center ⇒ 4pt
///   from the right / bottom.
/// - attach: standalone `AttachButton` — a 32pt circle anchored to the
///   pill's bottom edge with 8pt spacing. Bottom-aligning (rather than
///   centering) means the `+` stays glued to the text row even when the
///   pill grows upward to host a thumbnail strip, instead of drifting up
///   to the overall pill center.
struct InputBarView2: View {
    static let cornerRadius: CGFloat = 16
    private let pillMinHeight: CGFloat = 32
    private let sendButtonSize: CGFloat = 24
    private let sendButtonInset: CGFloat = 4
    private let attachToPillSpacing: CGFloat = 8
    private let textLeadingPadding: CGFloat = 12
    private let textTrailingPadding: CGFloat = 4
    private let textVerticalPadding: CGFloat = 7.5
    private let thumbnailSize: CGFloat = 48
    private let thumbnailSpacing: CGFloat = 8
    private let thumbnailTopPadding: CGFloat = 8
    private let thumbnailBottomPadding: CGFloat = 8
    private let thumbnailHorizontalPadding: CGFloat = 12
    private let iconPointSize: CGFloat = 13
    private let animationDuration: TimeInterval = 0.35

    /// Image extensions that route a dropped/picked file through the image
    /// path (base64 send + thumbnail preview) instead of the generic file
    /// path (`@path` mention in the outgoing text).
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "tif",
    ]

    /// UTTypes accepted by `.onDrop`. We accept file URLs (Finder, code
    /// editors, screenshot HUDs that *have* materialised the file) **and**
    /// raw image UTTypes so screenshot HUD drags that only advertise
    /// `public.png` (no URL conformance) still attach as in-memory images.
    private static let acceptedDropTypes: [UTType] = [
        .fileURL, .image, .png, .jpeg, .tiff, .heic, .gif, .bmp, .webP,
    ]

    /// One attached file or in-memory image. Identifiable so the thumbnail
    /// strip can `ForEach` with stable per-card hover state.
    struct Attachment: Equatable, Identifiable {
        enum Kind: Equatable {
            /// Decoded once at attach-time so we don't pay an `NSImage`
            /// decode each layout pass; sent via
            /// `Session.send(image:mediaType:caption:)`.
            case image(data: Data, mediaType: String)
            /// Absolute path on disk; sent inline as `@<path>` in the
            /// outgoing text so the CLI can read it on demand.
            case file(path: String)
        }

        let id: UUID
        let kind: Kind
        /// Image thumbnail or system file icon, used by the thumbnail
        /// strip; for files this is `NSWorkspace.shared.icon(forFile:)`.
        let thumbnail: NSImage
        /// Display name for the file row (and tooltip for image rows).
        let filename: String

        init(id: UUID = UUID(), kind: Kind, thumbnail: NSImage, filename: String) {
            self.id = id
            self.kind = kind
            self.thumbnail = thumbnail
            self.filename = filename
        }

        static func == (lhs: Attachment, rhs: Attachment) -> Bool {
            lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.filename == rhs.filename
        }
    }

    /// Payload handed to `onSubmit`. Any combination of `text`, `images`,
    /// and `filePaths` can be non-empty (at least one is, by `canSend`).
    /// `RootView2.submit(_:sessionId:)` composes them into one or more
    /// `Session.send(...)` calls.
    struct Submission {
        let text: String
        let images: [(data: Data, mediaType: String)]
        let filePaths: [String]
    }

    /// Injected by the caller. Only fired when the message has at least a
    /// non-whitespace text OR an attachment.
    var onSubmit: (Submission) -> Void = { _ in }
    /// Fired when the stop button is pressed (only clickable while `isRunning`
    /// shows stop). Callers typically forward to `Session.interrupt()`.
    var onStop: () -> Void = {}
    /// Running state from the handle. true → show stop button; false → send
    /// button gated by `canSend`. No local `@State` copy — avoids drift from
    /// the handle.
    var isRunning: Bool = false
    /// External gate stacked on top of the text/attachment check. RootView2
    /// sets it to `false` in compose mode while no project folder is picked,
    /// so the send button greys out until the user chooses a target — the
    /// draft would otherwise silently fall back to `$HOME` at submit.
    var submitEnabled: Bool = true
    /// Coordinate space in which to report `onAttachRect` / `onPillRect`.
    /// `nil` disables geometry reporting (e.g. previews).
    var coordSpace: String? = nil
    /// Fired with the attach button's frame (in `coordSpace`). The bottom
    /// scrim uses it to cut a *Circle* hole — bar chrome should never see
    /// a gray gradient on top of the LG button.
    var onAttachRect: ((CGRect) -> Void)? = nil
    /// Fired with the pill's frame (in `coordSpace`). The bottom scrim
    /// uses it to cut a *RoundedRectangle* hole. Reported separately from
    /// `onAttachRect` so the 8pt spacing between the two is NOT cut,
    /// letting the scrim's gradient bridge them naturally.
    var onPillRect: ((CGRect) -> Void)? = nil
    /// Working directory for file mentions and slash command lookups.
    /// Nil while still composing a draft with no folder picked — both
    /// triggers display a "pick a folder first" hint in that state.
    var directory: String? = nil
    /// Extra workspace dirs joined with `directory` for multi-dir file
    /// lookups (each match carries a `lastPathComponent` badge).
    var additionalDirs: [String] = []
    /// Plugin search dirs forwarded to `SlashCommandStore`'s cache key
    /// (a different plugin set means a different command set).
    var pluginDirs: [String] = []
    /// Chat mode passes the session's already-resolved slash command
    /// list to bypass `SlashCommandStore`'s temp-CLI fetch. Compose
    /// mode leaves this `nil` so the store goes through its cache
    /// (warmed by `CompletionPrewarmer`).
    var knownSlashCommands: [SlashCommand]? = nil
    /// Storage key for the unsent draft. `nil` disables persistence
    /// (used by `#Preview`). Chat mode passes the session id; compose
    /// mode passes `InputDraftStore.newSessionKey` so the draft
    /// survives the lazily-allocated `draftSessionId` regenerating.
    var draftKey: String? = nil
    /// Dispatcher for CCTerm-native builtin slash commands (`/new`,
    /// `/clear`). Injected by the host VC; threaded into the completion
    /// trigger context so the slash rule can offer + fire them. `nil` (the
    /// default) disables builtins — the compose card and previews leave it
    /// unset.
    var onBuiltinCommand: ((BuiltinSlashCommand) -> Void)? = nil
    /// When true, the text field grabs first responder as the bar appears.
    /// Set by the `/new` / `/clear` draft-landing bar so the user can type
    /// immediately; the chat resting bar and compose card leave it false.
    var autofocus: Bool = false

    @Environment(InputDraftStore.self) private var draftStore
    @State private var text: String = ""
    @State private var isFocused: Bool = false
    @State private var desiredCursorPosition: Int?
    @State var attachments: [Attachment] = []
    @State private var previewImage: PreviewImage?
    /// True while a file drag is hovering anywhere over the bar. Drives the
    /// dashed accent stroke on the pill + attach button.
    @State private var isDropTargeted: Bool = false
    /// Drives the completion popup that sits directly above the
    /// thumbnail strip (or directly above the text row when no
    /// attachment is present). Created once per InputBarView2; the bar
    /// rewires its provider closures every render via `triggerContext`.
    @State private var completion = CompletionViewModel()

    var body: some View {
        // `.bottom` (not `.center`) so the attach button always sits at
        // the bottom 32pt of the pill where the text row lives. Without
        // an attachment, pill and attach are both 32pt high → centers
        // coincide. With attachments, pill grows upward to host the
        // thumbnail strip, but the text row stays anchored to the
        // bottom — bottom-alignment keeps the `+` centered on the text
        // row rather than drifting to the overall pill center.
        HStack(alignment: .bottom, spacing: attachToPillSpacing) {
            AttachButton(
                onPick: presentPicker,
                isDropTargeted: isDropTargeted
            )
            .modifier(ReportFrame(coordSpace: coordSpace, action: onAttachRect))
            pill
                .modifier(ReportFrame(coordSpace: coordSpace, action: onPillRect))
        }
        .onDrop(of: Self.acceptedDropTypes, isTargeted: $isDropTargeted, perform: handleDrop)
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        .animation(.smooth(duration: animationDuration), value: isRunning)
        .animation(.smooth(duration: animationDuration), value: attachments.isEmpty)
        .sheet(item: $previewImage) { item in
            ImagePreviewView(thumbnail: item.image)
        }
        // Off-main load of the persisted draft. Re-fires on draftKey
        // change (session switch). Only restores when the local state
        // is still untouched — if the user started typing before the
        // disk read returned, we throw the loaded value away rather
        // than clobber in-flight input.
        .task(id: draftKey) {
            guard let key = draftKey else { return }
            guard let draft = await draftStore.load(sessionId: key) else { return }
            if text.isEmpty && attachments.isEmpty {
                text = draft.text
                attachments = draft.filePaths.map { Self.restoreFileAttachment(path: $0) }
            }
        }
        .onChange(of: text) { _, _ in scheduleDraftSave() }
        .onChange(of: attachments) { _, _ in scheduleDraftSave() }
        .onAppear { if autofocus { isFocused = true } }
    }

    /// Snapshot the bar's persistable state and hand it to the store.
    /// Empty input routes through `save` too — the store turns an
    /// empty draft into a `clear` so we never leave a zero-byte file
    /// on disk.
    private func scheduleDraftSave() {
        guard let key = draftKey else { return }
        let filePaths: [String] = attachments.compactMap { attachment in
            if case .file(let path) = attachment.kind { return path }
            return nil
        }
        draftStore.save(
            InputDraft(text: text, filePaths: filePaths, updatedAt: Date()),
            for: key
        )
    }

    /// Rehydrate a `.file` attachment from a persisted path. The system
    /// icon falls back to a generic file glyph when the file has moved
    /// or been deleted since the draft was saved — the user can hit
    /// the remove X to drop a stale entry.
    private static func restoreFileAttachment(path: String) -> Attachment {
        let url = URL(fileURLWithPath: path)
        let icon = NSWorkspace.shared.icon(forFile: path)
        return Attachment(
            kind: .file(path: path),
            thumbnail: icon,
            filename: url.lastPathComponent
        )
    }

    // MARK: - Pill

    private var pill: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Completion popup sits at the top of the pill, ABOVE the
            // thumbnail strip. Priority: completion outranks attachments,
            // so an open completion list stays anchored to the text row
            // even when images are attached. No animation — popup show /
            // hide should feel instant, not crossfade.
            if completion.isActive {
                CompletionListView(
                    viewModel: completion,
                    onConfirm: { item in confirmCompletion(item: item) },
                    onDeleteRecent: { item in
                        guard let dirItem = item as? DirectoryCompletionItem else { return }
                        DirectoryCompletionProvider.removeFromRecent(dirItem.path)
                        completion.removeItem {
                            ($0 as? DirectoryCompletionItem)?.path == dirItem.path
                        }
                    }
                )
                Divider()
            }
            if !attachments.isEmpty {
                thumbnailStrip
                Divider()
            }
            HStack(alignment: .bottom, spacing: 0) {
                textArea
                sendOrStopButton
                    .padding(.trailing, sendButtonInset)
                    .padding(.bottom, sendButtonInset)
            }
        }
        .frame(minHeight: pillMinHeight)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .barSurface(cornerRadius: Self.cornerRadius)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            }
        }
    }

    /// Horizontally scrollable strip — multiple attachments stack left-to-
    /// right; once they overflow the pill width the strip scrolls (cards
    /// keep their full size rather than shrinking). `.scrollIndicators(.never)`
    /// matches Apple's compose-area aesthetic in Mail / Messages.
    private var thumbnailStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: thumbnailSpacing) {
                ForEach(attachments) { attachment in
                    attachmentCard(for: attachment)
                }
            }
            .padding(.vertical, thumbnailTopPadding)
            .padding(.horizontal, thumbnailHorizontalPadding)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: thumbnailSize + thumbnailTopPadding + thumbnailBottomPadding)
    }

    /// Card for one attachment. Image kind shows a clickable thumbnail
    /// (taps open the preview sheet); file kind shows icon + filename.
    /// Each card owns its own hover state via `AttachmentCard`.
    @ViewBuilder
    private func attachmentCard(for attachment: Attachment) -> some View {
        switch attachment.kind {
        case .image:
            AttachmentCard(
                onRemove: { remove(attachment) },
                content: {
                    Button(action: { previewImage = PreviewImage(image: attachment.thumbnail) }) {
                        Image(nsImage: attachment.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: thumbnailSize, height: thumbnailSize)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(attachment.filename)
                })
        case .file(let path):
            AttachmentCard(
                onRemove: { remove(attachment) },
                content: {
                    HStack(spacing: 8) {
                        Image(nsImage: attachment.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: thumbnailSize - 16, height: thumbnailSize - 16)
                        Text(attachment.filename)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: thumbnailSize)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .help(path)
                })
        }
    }

    private func remove(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    // MARK: - Text Area

    private var textArea: some View {
        TextInputView(
            text: $text,
            isEnabled: true,
            placeholder: String(localized: "Send a message"),
            font: .systemFont(ofSize: 14),
            minLines: 1,
            maxLines: 10,
            // 7.5pt applied as `textContainerInset` inside NSTextView so the
            // scroll view's frame fills the full 32pt pill — the click /
            // I-beam region matches what users perceive as "the text field"
            // even though the glyphs themselves remain visually centered.
            verticalContentInset: textVerticalPadding,
            onTextChanged: { newText, cursor in
                completion.checkTrigger(
                    text: newText,
                    cursorLocation: cursor,
                    hasMarkedText: false,
                    context: triggerContext
                )
            },
            onCommandReturn: {
                // Completion takes priority: hitting Enter / Cmd+Enter
                // while the popup is open confirms the highlighted
                // entry rather than sending the half-typed message.
                if completion.isActive,
                    let result = completion.confirmSelection()
                {
                    applyReplacement(result)
                    return
                }
                handleSend()
            },
            onEscape: {
                if completion.isActive {
                    completion.dismiss()
                    return
                }
                if isRunning { onStop() }
            },
            keyInterceptor: handleCompletionKey,
            isFocused: $isFocused,
            desiredCursorPosition: $desiredCursorPosition
        )
        .padding(.leading, textLeadingPadding)
        .padding(.trailing, textTrailingPadding)
    }

    // MARK: - Send / Stop Button

    @ViewBuilder
    private var sendOrStopButton: some View {
        if isRunning {
            circleButton(
                icon: "stop.fill",
                color: Color(nsColor: .systemGray),
                action: onStop
            )
            .transition(.scale.combined(with: .opacity))
        } else {
            circleButton(
                icon: "arrow.up",
                color: .accentColor,
                action: handleSend
            )
            .opacity(canSend ? 1.0 : 0.4)
            .disabled(!canSend)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var canSend: Bool {
        guard submitEnabled else { return false }
        let textOK = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return textOK || !attachments.isEmpty
    }

    private func handleSend() {
        guard canSend else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var images: [(data: Data, mediaType: String)] = []
        var filePaths: [String] = []
        for attachment in attachments {
            switch attachment.kind {
            case .image(let data, let mediaType):
                images.append((data: data, mediaType: mediaType))
            case .file(let path):
                filePaths.append(path)
            }
        }
        let submission = Submission(text: trimmed, images: images, filePaths: filePaths)
        // Reset local state AND clear the persisted draft *before* handing
        // off to `onSubmit`. In compose mode `onSubmit` promotes the draft
        // and calls `model.select(.session(_))`, which now swaps the routed
        // child VC **synchronously** — this view is torn down in the same
        // source phase. After that teardown SwiftUI never re-evaluates the
        // body, so the reactive `.onChange(of: text) → scheduleDraftSave`
        // clear can't fire and the new-session draft would survive the send
        // (reappearing on the next New Session). Clearing the store directly
        // here is teardown-proof — it runs on the stack regardless.
        text = ""
        attachments = []
        completion.dismiss()
        if let key = draftKey {
            draftStore.clear(key)
        }
        onSubmit(submission)
    }

    // MARK: - Completion glue

    /// Built fresh per render so trigger rules see the latest
    /// `directory` / `additionalDirs` / `knownSlashCommands` values
    /// (e.g. after the configurator's folder switch or after the
    /// session's initialize response lands).
    private var triggerContext: CompletionTriggerContext {
        CompletionTriggerContext(
            directory: directory,
            additionalDirs: additionalDirs,
            pluginDirs: pluginDirs,
            knownSlashCommands: knownSlashCommands,
            onBuiltinCommand: onBuiltinCommand
        )
    }

    /// Keyboard navigation while the popup is open. Returns true when
    /// the event is consumed; the underlying text view does nothing
    /// further with it.
    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard completion.isActive else { return false }
        switch event.keyCode {
        case 126:  // Up
            completion.moveSelectionUp()
            return true
        case 125:  // Down
            completion.moveSelectionDown()
            return true
        case 48, 36:  // Tab or Return — both confirm the highlighted item.
            // The interceptor runs before InputNSTextView's send-key
            // switch, so swallowing Return here confirms the completion
            // instead of inserting a newline (the default in commandEnter
            // mode).
            if let result = completion.confirmSelection() {
                applyReplacement(result)
            }
            return true
        default:
            return false
        }
    }

    /// Run a completion replacement: splice `result.replacement` into
    /// the text at `result.range` and move the cursor to the end of the
    /// inserted text via `desiredCursorPosition`.
    private func confirmCompletion(item: any CompletionItem) {
        guard completion.isActive else { return }
        // CompletionListView taps already update selectedIndex before
        // invoking the callback, so confirm the highlighted row.
        if let result = completion.confirmSelection() {
            applyReplacement(result)
        }
    }

    private func applyReplacement(_ result: (range: NSRange, replacement: String)) {
        let ns = text as NSString
        guard result.range.location >= 0,
            result.range.location + result.range.length <= ns.length
        else { return }
        text = ns.replacingCharacters(in: result.range, with: result.replacement)
        desiredCursorPosition = result.range.location + (result.replacement as NSString).length
    }

    // MARK: - Picker

    /// Single unified picker — any file. The thumbnail strip decides how
    /// to render the result (image preview vs. file icon) based on the
    /// extension; same dispatch as the drag-and-drop path.
    fileprivate func presentPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Choose a file to attach")
        panel.begin { [self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                attachPickedURL(url)
            }
        }
    }

    /// Shared dispatch for picked / dropped URLs: image extensions take
    /// the image flow (base64 send + preview); anything else becomes a
    /// generic file mention (`@<absolute path>` in the outgoing text).
    private func attachPickedURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) {
            attachImage(at: url)
        } else {
            attachFile(at: url)
        }
    }

    // MARK: - Attach helpers

    /// Read the file at `url`, derive a media type from its extension, and
    /// build a thumbnail.
    fileprivate func attachImage(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let thumb = NSImage(data: data) ?? NSImage()
        appendAttachment(
            Attachment(
                kind: .image(data: data, mediaType: mediaType(for: url)),
                thumbnail: thumb,
                filename: url.lastPathComponent
            ))
    }

    /// Attach the file at `url` as a non-image "mention" — its absolute path
    /// will be sent inline as `@<path>` in the next message. Thumbnail uses
    /// the system file icon (`NSWorkspace.shared.icon(forFile:)`), which
    /// honors the file's type-derived icon (Finder-style).
    fileprivate func attachFile(at url: URL) {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appendAttachment(
            Attachment(
                kind: .file(path: url.path),
                thumbnail: icon,
                filename: url.lastPathComponent
            ))
    }

    /// Image data dropped without an associated file URL (e.g. screenshot
    /// HUD drag). `mediaType` lines up with what the provider advertised so
    /// the wire format matches what the bytes actually are.
    private func attachImageData(_ data: Data, mediaType: String, filename: String) {
        let thumb = NSImage(data: data) ?? NSImage()
        appendAttachment(
            Attachment(
                kind: .image(data: data, mediaType: mediaType),
                thumbnail: thumb,
                filename: filename
            ))
    }

    private func appendAttachment(_ attachment: Attachment) {
        attachments.append(attachment)
    }

    private func mediaType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
            let mime = type.preferredMIMEType
        {
            return mime
        }
        return "image/png"
    }

    // MARK: - Drag and drop

    /// Process every provider in the drop. Each one is tried as (1) a file
    /// URL (Finder, code editors, materialised screenshot drags), then (2)
    /// in-memory image data (screenshot HUD that only advertises
    /// `public.png` etc.). Returns `true` if at least one provider was
    /// scheduled to load — SwiftUI uses this to decide whether to play the
    /// drop animation.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var consumedAny = false
        for provider in providers {
            if loadAsURL(provider) {
                consumedAny = true
                continue
            }
            if loadAsImageData(provider) {
                consumedAny = true
                continue
            }
        }
        return consumedAny
    }

    /// Try to coerce the provider into a `URL`. We probe two paths because
    /// not every drag source registers URL conformance, but most still
    /// expose `public.file-url` as a typed item.
    private func loadAsURL(_ provider: NSItemProvider) -> Bool {
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                guard let url = object as? URL else { return }
                DispatchQueue.main.async {
                    self.attachPickedURL(url)
                }
            }
            return true
        }
        let identifier = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return false }
        provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
            let url: URL?
            if let directURL = item as? URL {
                url = directURL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            guard let url else { return }
            DispatchQueue.main.async {
                self.attachPickedURL(url)
            }
        }
        return true
    }

    /// Try to read raw image bytes from the provider. Walks the common
    /// bitmap UTTypes in priority order (PNG first since the screenshot HUD
    /// always advertises `public.png`). The provider's `suggestedName`
    /// becomes the filename when present, otherwise we synthesise one with
    /// the matched extension so it reads sensibly in the strip.
    private func loadAsImageData(_ provider: NSItemProvider) -> Bool {
        let candidates: [(UTType, String, String)] = [
            (.png, "image/png", "png"),
            (.jpeg, "image/jpeg", "jpg"),
            (.heic, "image/heic", "heic"),
            (.tiff, "image/tiff", "tiff"),
            (.gif, "image/gif", "gif"),
            (.bmp, "image/bmp", "bmp"),
            (.webP, "image/webp", "webp"),
        ]
        for (type, mediaType, ext) in candidates {
            guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }
            let suggested = provider.suggestedName
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data, !data.isEmpty else { return }
                let filename = Self.imageDropFilename(suggested: suggested, ext: ext)
                DispatchQueue.main.async {
                    self.attachImageData(data, mediaType: mediaType, filename: filename)
                }
            }
            return true
        }
        return false
    }

    private static func imageDropFilename(suggested: String?, ext: String) -> String {
        if let name = suggested, !name.isEmpty {
            return ((name as NSString).pathExtension.isEmpty) ? "\(name).\(ext)" : name
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        return "screenshot-\(stamp).\(ext)"
    }

    // MARK: - Helpers

    private func circleButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: sendButtonSize, height: sendButtonSize)
                .background(Circle().fill(color))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Geometry reporting

/// Attaches an `.onGeometryChange` in `coordSpace` (when both `coordSpace`
/// and `action` are non-nil) and forwards the rect. Centralized so attach
/// and pill report through identical machinery; no-op when the host
/// doesn't need geometry (previews, isolated screenshots).
private struct ReportFrame: ViewModifier {
    let coordSpace: String?
    let action: ((CGRect) -> Void)?

    func body(content: Content) -> some View {
        if let coordSpace, let action {
            content.onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(coordSpace))
            } action: { rect in
                action(rect)
            }
        } else {
            content
        }
    }
}

// MARK: - Attachment card with hover-X

/// Wraps an attachment view (image thumbnail or file icon+name) and
/// overlays a top-trailing X that fades in on hover. Each instance owns
/// its own `@State`, so per-card hover doesn't bleed across siblings in
/// the multi-attachment strip.
private struct AttachmentCard<Content: View>: View {
    let onRemove: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered: Bool = false

    var body: some View {
        content()
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.65))
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .padding(2)
                .opacity(isHovered ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .accessibilityLabel(String(localized: "Remove attachment"))
            }
            .onHover { isHovered = $0 }
    }
}

// MARK: - Image Preview

/// Modal preview for an attached image. Sized to the image's natural aspect
/// ratio with reasonable bounds; Done dismisses.
private struct ImagePreviewView: View {
    let thumbnail: NSImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(
            minWidth: 360, idealWidth: 520, maxWidth: 800,
            minHeight: 280, idealHeight: 420, maxHeight: 720
        )
    }
}

/// Wrapper that gives the preview sheet a value-type `id` source (the
/// per-presentation UUID) and a typed `NSImage` payload. Avoids declaring
/// a retroactive `Identifiable` conformance on `NSImage`.
private struct PreviewImage: Identifiable {
    let id = UUID()
    let image: NSImage
}

// MARK: - Preview

#Preview {
    ZStack {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            InputBarView2()
                .frame(width: 640)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
    }
    .frame(width: 800, height: 600)
    .environment(
        InputDraftStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()))
    )
}
