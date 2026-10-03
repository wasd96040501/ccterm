import AppKit
import DisplayModels
import SwiftUI

/// The About window's content: the app's icon, its name over its version and
/// build, and the commit it was built from. 320 wide, as tall as it needs.
struct AboutView: View {
    let content: AboutContent
    let icon: NSImage?

    var body: some View {
        VStack(spacing: 16) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            VStack(spacing: 4) {
                Text(content.name)
                    .font(.title2.weight(.semibold))
                Text(String(localized: "Version \(content.version) (\(content.build))", bundle: .module))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(String(localized: "Commit", bundle: .module))
                    .foregroundStyle(.secondary)
                Text(content.commit)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            .font(.callout)
        }
        .padding(24)
        .frame(width: 320)
    }
}

#Preview {
    AboutView(
        content: AboutContent(
            name: "ccterm", windowTitle: "About ccterm", version: "1.0", build: "1", commit: "0000000"),
        icon: NSApp.applicationIconImage)
}
