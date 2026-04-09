import SwiftUI

struct ArchiveView: View {
    let sessionService: SessionService
    @Bindable var sidebarViewModel: SidebarViewModel
    @State private var records: [SessionRecord] = []

    var body: some View {
        Group {
            if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 40))
                        .foregroundStyle(.quaternary)
                    Text("No Archived Sessions")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(records) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title)
                                .lineLimit(1)
                            if let folder = record.groupingFolderName {
                                Text(folder)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Unarchive") {
                            sessionService.unarchive(record.sessionId)
                            sidebarViewModel.rebuildSections()
                            records = sessionService.findArchived()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .task { records = sessionService.findArchived() }
    }
}
