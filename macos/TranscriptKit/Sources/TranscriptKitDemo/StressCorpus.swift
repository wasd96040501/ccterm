import Foundation

/// A transcript of arbitrary length, built out of the real markdown in
/// `Corpus/`.
///
/// What the cold-load buttons on the control panel feed the transcript. The
/// documents are cut from Swift Evolution proposals and chapters of *The Swift
/// Programming Language* (see `Corpus/ATTRIBUTION.md`) rather than generated,
/// because the number the demo is showing off — how long an insert holds the
/// main thread — is dominated by the *spread* of row costs, not the average. A
/// thousand identical lorem paragraphs typeset in a thousand identical times
/// and would make any scheduling look even.
///
/// Cut at `##` boundaries because that is the granularity a chat turn has: a few
/// hundred words with a heading, sometimes a table or a code fence, occasionally
/// one section that runs for pages. A whole 90 KB proposal as one row would
/// instead measure the tail of the distribution and nothing else.
enum StressCorpus {

    /// `count` documents, cycling the corpus as many times as it takes.
    ///
    /// Every document is made **distinct** by the header stamped onto it, and
    /// that is load-bearing rather than cosmetic: identical sources would still
    /// be measured independently (`RowCache` is positional, and a `MarkdownMemo`
    /// belongs to one row), so sharing would not make the load cheaper — but it
    /// would make the transcript unreadable to scroll through, with no way to
    /// tell which copy of a section you are looking at or whether the row under
    /// the pointer is the one that just arrived.
    static func documents(count: Int) -> [String] {
        let sections = sections
        guard !sections.isEmpty else { return [] }
        return (0..<count).map { index in
            let section = sections[index % sections.count]
            return """
                ###### \(index + 1) / \(count) — \(section.origin)

                \(section.text)
                """
        }
    }

    /// How many distinct documents the corpus yields before it starts repeating.
    /// Shown on the panel, so the number of rows being asked for can be read
    /// against how much unique material is behind them.
    static var sectionCount: Int { sections.count }

    private struct Section {

        /// The file it was cut from, stamped onto the document so a row on
        /// screen can be traced back to its source while scrolling.
        let origin: String
        let text: String
    }

    /// Parsed once. The demo can ask for a hundred thousand rows and the reading
    /// and splitting happens on the first of them.
    private static let sections: [Section] = load()

    private static func load() -> [Section] {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Corpus"),
            let files = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else { return [] }

        // Sorted, so the transcript is the same one from run to run — a demo
        // whose row 4000 is a different document each time is one where "does
        // this row look right" cannot be asked twice.
        return
            files
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "ATTRIBUTION.md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { file -> [Section] in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
                return split(text).map {
                    Section(
                        origin: file.deletingPathExtension()
                            .lastPathComponent, text: $0)
                }
            }
    }

    /// Splits one file at its `##` headings, keeping each heading with the
    /// material under it.
    ///
    /// Level two rather than level one: both sources put a single `#` at the top
    /// of the file and everything else under it, so cutting at `#` would hand
    /// back one document per file.
    ///
    /// A fenced code block can contain a line that looks like a heading — a
    /// shell transcript, a diff, a markdown example, all of which are in here —
    /// so the scan tracks whether it is inside a fence. Without that, a document
    /// gets cut in half at a `## ` inside a fence and both halves render as
    /// something other than what the file says. Worth the six lines precisely
    /// because the failure is silent: the row still renders, just wrongly.
    private static func split(_ text: String) -> [String] {
        var sections: [String] = []
        var current: [Substring] = []
        var insideFence = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { insideFence.toggle() }

            if !insideFence, line.hasPrefix("## ") {
                if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n")) }

        // A section with nothing under its heading is a row with one line in it,
        // which measures to nothing interesting and reads as a gap in the
        // transcript. Both files have a few.
        return sections.filter { $0.count > 200 }
    }
}
