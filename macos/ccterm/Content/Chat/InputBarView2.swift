import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// V2 input bar (UI only — `handle` is optional for the standalone
/// preview).
///
/// Layout is a single squircle pill: text area on top, an inline divider,
/// and a footer row hosting all the session-scoped chrome (permission
/// picker, attach `+`, model + effort picker, context ring). Mirrors
/// Claude.app's compose surface — the user's choices and the textarea
/// share one container instead of being scattered around it.
///
/// - pill: `cornerRadius = 16`. Send button anchored to the text row's
///   bottom-right corner with a 4pt inset.
/// - footer: 28pt tall strip below the divider; attach button is the
///   22pt compact variant of `AttachButton`.
struct InputBarView2: View {
    static let cornerRadius: CGFloat = 16
    private let pillMinHeight: CGFloat = 32
    private let sendButtonSize: CGFloat = 24
    private let sendButtonInset: CGFloat = 4
    private let textLeadingPadding: CGFloat = 12
    private let textTrailingPadding: CGFloat = 4
    private let textVerticalPadding: CGFloat = 7.5
    private let thumbnailSize: CGFloat = 48
    private let thumbnailTopPadding: CGFloat = 8
    private let thumbnailBottomPadding: CGFloat = 8
    private let thumbnailLeadingPadding: CGFloat = 12
    private let iconPointSize: CGFloat = 13
    private let footerAttachSize: CGFloat = 22
    private let animationDuration: TimeInterval = 0.35

    /// Image attached to the next outgoing message. Cleared after a successful
    /// send. The thumbnail is derived from `data` once at attach-time so we
    /// don't pay an `NSImage` decode each layout pass.
    struct Attachment: Equatable {
        let data: Data
        let mediaType: String
        let thumbnail: NSImage
    }

    /// Payload handed to `onSubmit`. Either `text` is non-empty, or `image`
    /// is non-nil, or both. Callers route to `SessionHandle2.send(text:)` /
    /// `send(image:mediaType:caption:)` accordingly.
    struct Submission {
        let text: String
        let image: (data: Data, mediaType: String)?
    }

    /// Injected by the caller. Only fired when the message has at least a
    /// non-whitespace text OR an attached image.
    var onSubmit: (Submission) -> Void = { _ in }
    /// Fired when the stop button is pressed (only clickable while `isRunning`
    /// shows stop). Callers typically forward to `SessionHandle2.interrupt()`.
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
    /// Coordinate space in which to report `onPillRect`. `nil` disables
    /// geometry reporting (e.g. previews).
    var coordSpace: String? = nil
    /// Fired with the pill's frame (in `coordSpace`). The bottom scrim
    /// uses it to cut a `RoundedRectangle` hole so the pill — and the
    /// attach button it now contains — refracts the transcript directly
    /// without a gray gradient on top.
    var onPillRect: ((CGRect) -> Void)? = nil
    /// Optional handle for the per-session footer chrome (permission mode
    /// picker, model + effort picker, context ring). Wired by the chrome
    /// wrapper that owns the handle. nil hides the footer row entirely —
    /// keeps the standalone preview / non-session usage compiling.
    var handle: SessionHandle2? = nil

    @State private var text: String = ""
    @State private var isFocused: Bool = false
    @State private var desiredCursorPosition: Int?
    @State var attachment: Attachment?
    @State private var isPresentingPreview: Bool = false

    var body: some View {
        pill
            .modifier(ReportFrame(coordSpace: coordSpace, action: onPillRect))
            .animation(.smooth(duration: animationDuration), value: isRunning)
            .animation(.smooth(duration: animationDuration), value: attachment != nil)
            .sheet(isPresented: $isPresentingPreview) {
                if let attachment {
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
            if let handle {
                Divider()
                footerRow(handle: handle)
            }
        }
        .frame(minHeight: pillMinHeight)
        .barSurface(cornerRadius: Self.cornerRadius)
    }

    /// Bottom strip of session-scoped chrome. Layout mirrors
    /// Claude.app's compose footer: permission picker + attach button on
    /// the left, model + effort picker (with a small `ProgressView`
    /// while the catalog is fetching) on the right, context ring at the
    /// far right. Hidden when the handle isn't injected (e.g. the
    /// stand-alone preview).
    private func footerRow(handle: SessionHandle2) -> some View {
        HStack(spacing: 6) {
            PermissionModePicker(handle: handle)
            AttachButton(onPickImage: presentImagePicker, size: footerAttachSize)
            Spacer(minLength: 0)
            ModelEffortPicker(handle: handle)
            ContextRingButton(handle: handle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var thumbnailStrip: some View {
        // Strip is only mounted while `attachment != nil`, so the fallback
        // `NSImage()` keeps the Button label type unconditional —
        // `_ConditionalContent` labels occasionally drop the parent's
        // accessibility identifier under XCUI.
        let thumb = attachment?.thumbnail ?? NSImage()
        return HStack(spacing: 0) {
            Button(action: { isPresentingPreview = true }) {
                Image(nsImage: thumb)
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
            .overlay(alignment: .topTrailing) {
                Button(action: { attachment = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .padding(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, thumbnailTopPadding)
        .padding(.bottom, thumbnailBottomPadding)
        .padding(.leading, thumbnailLeadingPadding)
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
        let image: (data: Data, mediaType: String)? = attachment.map { ($0.data, $0.mediaType) }
        onSubmit(Submission(text: trimmed, image: image))
        text = ""
        attachment = nil
    }

    // MARK: - Image Picker

    fileprivate func presentImagePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose an image to attach")
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            attachImage(at: url)
        }
    }

    /// Read the file at `url`, derive a media type from its extension, and
    /// build a thumbnail.
    fileprivate func attachImage(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let thumb = NSImage(data: data) ?? NSImage()
        attachment = Attachment(data: data, mediaType: mediaType(for: url), thumbnail: thumb)
    }

    private func mediaType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
            let mime = type.preferredMIMEType
        {
            return mime
        }
        return "image/png"
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
