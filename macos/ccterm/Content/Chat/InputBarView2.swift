import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// V2 input bar (UI only, no session handle wiring).
///
/// Layout: `HStack(attach, pill)` where `pill` is a squircle container that
/// wraps either `HStack(text, sendButton)` (idle) or
/// `VStack(thumbnailStrip, Divider, HStack(text, sendButton))` (image
/// attached). Sizes are 20% smaller than the previous 40pt design, all on a
/// 4pt grid:
///
/// - pill: 32pt min height, `cornerRadius = 16`. Send button is concentric
///   with the bottom-right corner: button radius 12, shared center ⇒ 4pt
///   from the right / bottom.
/// - attach: a standalone 24pt circle in an HStack with the pill,
///   8pt spacing — Gestalt proximity (~ ⅓ element width) reads as "two
///   related but independent controls".
struct InputBarView2: View {
    static let cornerRadius: CGFloat = 16
    private let pillMinHeight: CGFloat = 32
    private let sendButtonSize: CGFloat = 24
    private let sendButtonInset: CGFloat = 4
    private let attachButtonSize: CGFloat = 24
    private let attachToPillSpacing: CGFloat = 8
    private let textLeadingPadding: CGFloat = 12
    private let textTrailingPadding: CGFloat = 4
    private let textVerticalPadding: CGFloat = 7.5
    private let thumbnailSize: CGFloat = 56
    private let thumbnailTopPadding: CGFloat = 8
    private let thumbnailBottomPadding: CGFloat = 8
    private let thumbnailLeadingPadding: CGFloat = 12
    private let iconPointSize: CGFloat = 13
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

    @State private var text: String = ""
    @State private var isFocused: Bool = false
    @State private var desiredCursorPosition: Int?
    @State var attachment: Attachment?
    @State private var isPresentingPreview: Bool = false

    var body: some View {
        HStack(alignment: .bottom, spacing: attachToPillSpacing) {
            attachButton
            pill
        }
        .animation(.smooth(duration: animationDuration), value: isRunning)
        .animation(.smooth(duration: animationDuration), value: attachment != nil)
        .sheet(isPresented: $isPresentingPreview) {
            if let attachment {
                ImagePreviewView(thumbnail: attachment.thumbnail)
            }
        }
    }

    // MARK: - Attach Button

    private var attachButton: some View {
        // SwiftUI `Menu` on macOS 26 renders as a `MenuButton` whose
        // accessibility node swallows child identifiers — putting
        // `.testIdentifier` on the Menu or its label closure is
        // silently dropped. The stable handle is `.accessibilityLabel`
        // on the Menu (sets the MenuButton's AX label); tests query
        // `app.menuButtons["Attach image or file"]`.
        Menu {
            Button {
                presentImagePicker()
            } label: {
                Label(String(localized: "Image"), systemImage: "photo")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: iconPointSize, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: attachButtonSize, height: attachButtonSize)
                .background(
                    Circle().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                )
                .overlay(
                    Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Semantic label for VoiceOver: replaces the SF-symbol-derived
        // default ("Add") with a meaningful word. Tests use it as the
        // primary query key — `app.menuButtons["Attach image or file"]`
        // — since the MenuButton swallows identifiers.
        .accessibilityLabel(String(localized: "Attach image or file"))
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
            .testIdentifier("InputBar2.AttachmentThumbnail")
            .overlay(alignment: .topTrailing) {
                Button(action: { attachment = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .padding(2)
                .testIdentifier("InputBar2.RemoveAttachment")
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
        .testIdentifier("InputBar2.TextField")
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
            .testIdentifier("InputBar2.StopButton")
            .transition(.scale.combined(with: .opacity))
        } else {
            circleButton(
                icon: "arrow.up",
                color: .accentColor,
                action: handleSend
            )
            .testIdentifier("InputBar2.SendButton")
            .opacity(canSend ? 1.0 : 0.4)
            .disabled(!canSend)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var canSend: Bool {
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
        .testIdentifier("InputBar2.ImagePreview")
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
