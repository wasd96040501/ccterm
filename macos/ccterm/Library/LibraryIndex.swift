import AgentSDK
import Foundation

/// What each session read as — whether the library shows it, under which
/// project and title, and the side transcripts it had — kept in a file between
/// launches, so a launch can show the library before reading anything but the
/// transcripts written since the last one. A record stands for its transcript
/// only while the transcript still has the modification date it was read at;
/// its side transcripts come and go without that date moving, so they are
/// what was last seen, not what is.
///
/// Bump `currentVersion` whenever what a session reads as changes (which
/// sessions are shown, how a project, a title or a side transcript's node is
/// made): a file of another version reads as empty.
struct LibraryIndex: Codable, Equatable, Sendable {
    /// One session as it read.
    struct Record: Codable, Equatable, Sendable {
        /// A shown session.
        struct Summary: Codable, Equatable, Sendable {
            /// Its project's directory.
            let project: String
            /// `nil` when the session has neither a title nor a prompt.
            let title: String?
            /// The nodes of its subagents and workflow runs.
            let children: [LibraryNode]
        }

        let modificationDate: Date
        /// `nil` for a session the library leaves out.
        let summary: Summary?

        /// The record with the side transcripts `children` instead.
        func relisting(_ children: [LibraryNode]) -> Record {
            Record(
                modificationDate: modificationDate,
                summary: summary.map { Summary(project: $0.project, title: $0.title, children: children) })
        }
    }

    private static let currentVersion = 1

    private var version = LibraryIndex.currentVersion
    /// By transcript path.
    private var records: [String: Record] = [:]

    init() {}

    /// The index written at `url`; empty if there is none, it can't be read,
    /// or it is of another version.
    init(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url),
            let index = try? PropertyListDecoder().decode(Self.self, from: data),
            index.version == Self.currentVersion
        else { return }
        self = index
    }

    /// An index of these records and no others: a transcript deleted since
    /// the last one leaves it.
    init(_ records: [(SessionFile, Record)]) {
        for (session, record) in records { self.records[session.url.path] = record }
    }

    /// What `session` read as, if its transcript has not changed since.
    func record(for session: SessionFile) -> Record? {
        records[session.url.path].flatMap { $0.modificationDate == session.modificationDate ? $0 : nil }
    }

    func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
