import SwiftUI

/// Borderless, header-only disclosure container.
///
/// Visual contract — different from ``ToolBlock``:
/// - no background, no border, no rounded shell
/// - header is a button row with chevron + caller-supplied label
/// - 8pt gap between header and the first child; 8pt between children
/// - body is mounted but zero-height when collapsed (preserves child @State)
struct GroupBlock<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    let content: () -> Content
    let label: () -> Label

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self._isExpanded = isExpanded
        self.content = content
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            bodyArea
                .frame(height: isExpanded ? nil : 0, alignment: .top)
                .clipped()
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                label()
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var bodyArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

#Preview("Collapsed") {
    @Previewable @State var expanded = false
    GroupBlock(isExpanded: $expanded) {
        Text("first child")
        Text("second child")
        Text("third child")
    } label: {
        Text("Read 3 files · Searched 1 pattern")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
    .padding()
    .frame(width: 480)
}

#Preview("Expanded") {
    @Previewable @State var expanded = true
    GroupBlock(isExpanded: $expanded) {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.1))
            .frame(height: 36)
            .overlay(Text("block 1").font(.system(size: 12)))
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.1))
            .frame(height: 36)
            .overlay(Text("block 2").font(.system(size: 12)))
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.1))
            .frame(height: 36)
            .overlay(Text("block 3").font(.system(size: 12)))
    } label: {
        Text("Reading foo.swift")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
    .padding()
    .frame(width: 480)
}
