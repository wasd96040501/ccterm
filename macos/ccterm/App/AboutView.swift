import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            VStack(spacing: 4) {
                Text("ccterm")
                    .font(.title2.weight(.semibold))
                Text("Version \(BuildInfo.marketingVersion) (\(BuildInfo.buildNumber))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text("Commit")
                    .foregroundStyle(.secondary)
                Text(BuildInfo.gitCommit)
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
    AboutView()
}
