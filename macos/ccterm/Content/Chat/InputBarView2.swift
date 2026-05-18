import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// V2 input bar (UI only, no session handle wiring).
///
/// Layout: `HStack(attach, pill)` where `pill` is a squircle container that
/// wraps either `HStack(text, sendButton)` (idle) or
/// `VStack(thumbnailStrip, Divider, HStack(text, sendButton))` (image or
/// file attached). Sizes are 20% smaller than the previous 40pt design,
/// all on a 4pt grid:
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
    private let thumbnailTopPadding: CGFloat = 8
    private let thumbnailBottomPadding: CGFloat = 8
    private let thumbnailLeadingPadding: CGFloat = 12
    private let iconPointSize: CGFloat = 13
    private let animationDuration: TimeInterval = 0.35

    /// Image extensions that route a dropped/picked file through the image
    /// path (base64 send + thumbnail preview) instead of the generic file
    /// path (`@path` mention in the outgoing text).
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "tif",
    ]

    /// Attachment payload for the next outgoing message. Single-slot
    /// (drop / pick replaces an existing attachment).
    struct Attachment: Equatable {
        enum Kind: Equatable {
            /// Decoded once at attach-time so we don't pay an `NSImage`
            /// decode each layout pass; sent via
            /// `Session.send(image:mediaType:caption:)`.
            case image(data: Data, mediaType: String)
            /// Absolute path on disk; sent inline as `@<path>` in the
            /// outgoing text so the CLI can read it on demand.
            case file(path: String)
        }

        let kind: Kind
        /// Image thumbnail or system file icon, used by the thumbnail
        /// strip; for files this is `NSWorkspace.shared.icon(forFile:)`.
        let thumbnail: NSImage
        /// Display name for the file row (and tooltip for image rows).
        let filename: String

        static func == (lhs: Attachment, rhs: Attachment) -> Bool {
            lhs.kind == rhs.kind && lhs.filename == rhs.filename
        }
    }

    /// Payload handed to `onSubmit`. Either `text` is non-empty, an `image`
    /// is attached, or a `filePath` is attached. Callers route to the
    /// appropriate `Session.send(...)` overload.
    struct Submission {
        let text: String
        let image: (data: Data, mediaType: String)?
        let filePath: String?
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

    @State private var text: String = ""
    @State private var isFocused: Bool = false
    @State private var desiredCursorPosition: Int?
    @State var attachment: Attachment?
    @State private var isPresentingPreview: Bool = false
    @State private var isThumbHovered: Bool = false
    /// True while a file drag is hovering anywhere over the bar. Drives the
    /// dashed accent stroke on the pill + attach button.
    @State private var isDropTargeted: Bool = false

    var body: some View {
        // `.bottom` (not `.center`) so the attach button always sits at
        // the bottom 32pt of the pill where the text row lives. Without
        // an attachment, pill and attach are both 32pt high → centers
        // coincide. With an attachment, pill grows upward to host the
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        .animation(.smooth(duration: animationDuration), value: isRunning)
        .animation(.smooth(duration: animationDuration), value: attachment != nil)
        .sheet(isPresented: $isPresentingPreview) {
            if let attachment, case .image = attachment.kind {
                ImagePreviewView(thumbnail: attachment.thumbnail)
            }
        }
    }

    // MARK: - Pill

    private var pill: some View {
        VStack(alignment: .leading, spacing: 0) {
            if attachment != nil {
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

    @ViewBuilder
    private var thumbnailStrip: some View {
        if let attachment {
            HStack(spacing: 0) {
                attachmentCard(for: attachment)
                Spacer(minLength: 0)
            }
            .padding(.top, thumbnailTopPadding)
            .padding(.bottom, thumbnailBottomPadding)
            .padding(.leading, thumbnailLeadingPadding)
        }
    }

    /// Card for one attachment in the thumbnail strip. Image attachments are
    /// a clickable thumbnail; file attachments are icon + filename. Both
    /// expose a top-trailing X button that fades in on hover.
    @ViewBuilder
    private func attachmentCard(for attachment: Attachment) -> some View {
        switch attachment.kind {
        case .image:
            imageCard(thumbnail: attachment.thumbnail)
        case .file(let path):
            fileCard(icon: attachment.thumbnail, filename: attachment.filename, path: path)
        }
    }

    private func imageCard(thumbnail: NSImage) -> some View {
        Button(action: { isPresentingPreview = true }) {
            Image(nsImage: thumbnail)
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
        .modifier(AttachmentHoverRemove(isHovered: $isThumbHovered) { attachment = nil })
    }

    private func fileCard(icon: NSImage, filename: String, path: String) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: thumbnailSize - 16, height: thumbnailSize - 16)
            Text(filename)
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
        .modifier(AttachmentHoverRemove(isHovered: $isThumbHovered) { attachment = nil })
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
            onCommandReturn: { handleSend() },
            onEscape: { if isRunning { onStop() } },
            isFocused: $isFocused,
            desiredCursorPosition: $desiredCursorPosition
        )
        .padding(.leading, textLeadingPadding)
        .padding(.trailing, textTrailingPadding)
        // (32 - 17)/2 = 7.5: single-line case, 7.5 top + bottom centers the
        // ~17pt line height (14pt system font) within the 32pt container.
        .padding(.vertical, textVerticalPadding)
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
        return textOK || attachment != nil
    }

    private func handleSend() {
        guard canSend else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var image: (data: Data, mediaType: String)? = nil
        var filePath: String? = nil
        if let kind = attachment?.kind {
            switch kind {
            case .image(let data, let mediaType):
                image = (data: data, mediaType: mediaType)
            case .file(let path):
                filePath = path
            }
        }
        onSubmit(Submission(text: trimmed, image: image, filePath: filePath))
        text = ""
        attachment = nil
    }

    // MARK: - Picker

    /// Single unified picker — any file. The thumbnail strip decides how
    /// to render the result (image preview vs. file icon) based on the
    /// extension; same dispatch as the drag-and-drop path.
    fileprivate func presentPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Choose a file to attach")
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            attachPickedURL(url)
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
        attachment = Attachment(
            kind: .image(data: data, mediaType: mediaType(for: url)),
            thumbnail: thumb,
            filename: url.lastPathComponent
        )
    }

    /// Attach the file at `url` as a non-image "mention" — its absolute path
    /// will be sent inline as `@<path>` in the next message. Thumbnail uses
    /// the system file icon (`NSWorkspace.shared.icon(forFile:)`), which
    /// honors the file's type-derived icon (Finder-style).
    fileprivate func attachFile(at url: URL) {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        attachment = Attachment(
            kind: .file(path: url.path),
            thumbnail: icon,
            filename: url.lastPathComponent
        )
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

    /// Single-attachment drop: take the first dropped file URL. If its
    /// extension matches a known image type, route through `attachImage` so
    /// the user gets the image-preview flow; otherwise treat it as a generic
    /// file attachment.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        guard provider.canLoadObject(ofClass: URL.self) else {
            // Fall back to UTType.fileURL data representation for older
            // sources that don't advertise URL conformance.
            return loadFileURL(from: provider)
        }
        _ = provider.loadObject(ofClass: URL.self) { object, _ in
            guard let url = object as? URL else { return }
            DispatchQueue.main.async {
                self.attachPickedURL(url)
            }
        }
        return true
    }

    private func loadFileURL(from provider: NSItemProvider) -> Bool {
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

// MARK: - Attachment hover remove button

/// Overlays a top-trailing X button that fades in while the attached row is
/// hovered. The button has its own circular `xmark.circle.fill` glyph
/// (already a white-on-dim circle in palette mode), positioned 2pt in from
/// the top-right corner. The hover state is hoisted into the parent so
/// removing the attachment doesn't leak per-card state.
private struct AttachmentHoverRemove: ViewModifier {
    @Binding var isHovered: Bool
    let onRemove: () -> Void

    func body(content: Content) -> some View {
        content
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
}
