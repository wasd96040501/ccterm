import SwiftUI

// MARK: - Status

/// Runtime status of a tool block. Drives header spinner / error badge and
/// whether the block is forced-expanded (errors always are).
enum ToolBlockStatus: Equatable {
    case idle
    case running
    case error(String)
}

// MARK: - ToolBlock

/// Generic shell for a tool block: icon + label header, optional expandable
/// content, built-in running / error states.
///
/// Modelled after `DisclosureGroup` — pass a `Label` (usually SwiftUI's
/// `Label(_:systemImage:)`) and the body content. The chevron, spinner and
/// error badge are rendered automatically based on ``ToolBlockStatus``.
///
/// ```swift
/// ToolBlock(status: status, isExpanded: $isExpanded) {
///     NativeBashView(command: command)
/// } label: {
///     Label("ls -la", systemImage: "terminal")
/// }
/// ```
///
/// For blocks with no collapsible body (e.g. `Read` on success), use the
/// header-only initialiser:
///
/// ```swift
/// ToolBlock(status: status) {
///     Label(path, systemImage: "doc.text")
/// }
/// ```
struct ToolBlock<Label: View, Content: View>: View {
    let status: ToolBlockStatus
    @Binding var isExpanded: Bool
    let content: () -> Content
    let label: () -> Label

    init(
        status: ToolBlockStatus = .idle,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.status = status
        self._isExpanded = isExpanded
        self.content = content
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // bodyArea is kept mounted even when collapsed so that its
            // subviews' `@State` (syntax-highlight tokens, diff hunks,
            // rendered markdown) survives collapse/expand cycles. We hide
            // it with a zero-height frame + clip + opacity rather than
            // removing it from the tree, so `.task { … }` runs once on
            // first appearance and the work is already done by the time
            // the user expands the block.
            bodyArea
                .frame(height: effectivelyExpanded ? nil : 0, alignment: .top)
                .clipped()
                .opacity(effectivelyExpanded ? 1 : 0)
                .allowsHitTesting(effectivelyExpanded)
        }
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 0.5))
    }

    // MARK: Header

    private var header: some View {
        Button {
            guard isExpandable else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                chevron
                label()
                    .labelStyle(.toolBlockHeader)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                trailingIndicator
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isExpandable)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(effectivelyExpanded ? 90 : 0))
            .frame(width: 10)
            .opacity(isExpandable ? 1 : 0)
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        switch status {
        case .idle:
            EmptyView()
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
    }

    // MARK: Body

    @ViewBuilder
    private var bodyArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .error(let message) = status, !message.isEmpty {
                errorBanner(message)
            }
            if Content.self != EmptyView.self {
                content()
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Derived

    private var isExpandable: Bool {
        if case .error = status { return true }
        return Content.self != EmptyView.self
    }

    private var effectivelyExpanded: Bool {
        isExpandable && isExpanded
    }

    private var backgroundColor: Color {
        Color.secondary.opacity(0.06)
    }

    private var borderColor: Color {
        if case .error = status { return Color.red.opacity(0.3) }
        return Color.secondary.opacity(0.15)
    }
}

// MARK: - Header-only initialiser

extension ToolBlock where Content == EmptyView {
    /// Header-only block — no chevron, no collapsible body (unless the block
    /// enters an error state, in which case the error banner is shown).
    init(
        status: ToolBlockStatus = .idle,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.init(
            status: status,
            isExpanded: .constant(false),
            content: { EmptyView() },
            label: label)
    }
}

// MARK: - Label style

/// Default label style for tool block headers: small icon flush with a
/// monospaced title. Callers can still apply their own `.labelStyle(...)`
/// on the outside to override.
private struct ToolBlockHeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            configuration.title
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}

extension LabelStyle where Self == ToolBlockHeaderLabelStyle {
    fileprivate static var toolBlockHeader: ToolBlockHeaderLabelStyle {
        ToolBlockHeaderLabelStyle()
    }
}

// MARK: - Previews

private struct PreviewHarness<C: View>: View {
    let height: CGFloat
    let content: C

    init(height: CGFloat = 220, @ViewBuilder _ content: () -> C) {
        self.height = height
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding()
        .frame(width: 520, height: height, alignment: .topLeading)
    }
}

#Preview("Idle — collapsed") {
    @Previewable @State var expanded = false
    PreviewHarness {
        ToolBlock(status: .idle, isExpanded: $expanded) {
            Text("Collapsible body content here.\nMultiple lines.")
                .font(.system(size: 12, design: .monospaced))
        } label: {
            Label("ls -la /usr/local/bin", systemImage: "terminal")
        }
    }
}

#Preview("Idle — expanded") {
    @Previewable @State var expanded = true
    PreviewHarness(height: 260) {
        ToolBlock(status: .idle, isExpanded: $expanded) {
            Text("Some body content revealed on expand.")
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            Label("/Users/example/project/README.md", systemImage: "pencil")
        }
    }
}

#Preview("Running") {
    @Previewable @State var expanded = false
    PreviewHarness {
        ToolBlock(status: .running, isExpanded: $expanded) {
            Text("streaming output…")
                .font(.system(size: 12, design: .monospaced))
        } label: {
            Label("make build", systemImage: "terminal")
        }
    }
}

#Preview("Error — auto-expanded banner") {
    @Previewable @State var expanded = false
    PreviewHarness(height: 260) {
        ToolBlock(
            status: .error("EACCES: permission denied, open '/etc/hosts'"),
            isExpanded: $expanded
        ) {
            Text("additional context below the banner")
                .font(.system(size: 12, design: .monospaced))
        } label: {
            Label("/etc/hosts", systemImage: "doc.text")
        }
    }
}

#Preview("Header-only (no body)") {
    PreviewHarness(height: 280) {
        ToolBlock(status: .idle) {
            Label("/Users/me/Source/repo/README.md", systemImage: "doc.text")
        }
        ToolBlock(status: .running) {
            Label("fetching…", systemImage: "globe")
        }
        ToolBlock(status: .error("File not found")) {
            Label("/missing/file.txt", systemImage: "doc.text")
        }
    }
}

#Preview("All states stacked") {
    @Previewable @State var a = false
    @Previewable @State var b = true
    @Previewable @State var c = false
    @Previewable @State var d = false
    PreviewHarness(height: 420) {
        ToolBlock(status: .idle, isExpanded: $a) {
            Text("idle collapsed body").font(.system(size: 12, design: .monospaced))
        } label: {
            Label("idle collapsed", systemImage: "terminal")
        }
        ToolBlock(status: .idle, isExpanded: $b) {
            Text("idle expanded body").font(.system(size: 12, design: .monospaced))
        } label: {
            Label("idle expanded", systemImage: "pencil")
        }
        ToolBlock(status: .running, isExpanded: $c) {
            Text("running body").font(.system(size: 12, design: .monospaced))
        } label: {
            Label("running", systemImage: "terminal")
        }
        ToolBlock(status: .error("something went wrong"), isExpanded: $d) {
            Text("error body").font(.system(size: 12, design: .monospaced))
        } label: {
            Label("error", systemImage: "exclamationmark.triangle")
        }
    }
}
