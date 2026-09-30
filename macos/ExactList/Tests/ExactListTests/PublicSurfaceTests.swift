import Foundation
import XCTest

/// Every public member of `ExactList` says what it mirrors (CLAUDE.md §2, §3):
/// its doc comment names an AppKit counterpart in backticks (`` `NS…` ``) or
/// states a `*Deviation`. A member that can say neither is the consumer's
/// preference and doesn't belong here.
///
/// Reads the sources themselves, as `SpecCoverageTests` reads the spec.
/// Overrides are left out, since their counterpart is the member they
/// override, and so are a protocol's default implementations, since their
/// requirement carries the doc.
final class PublicSurfaceTests: XCTestCase {

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ExactList")

    func testEveryPublicMemberNamesItsCounterpart() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var unexplained: [String] = []
        var checked = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            var inDefaults = false
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("extension ") {
                    inDefaults = line.contains("Delegate") || line.contains("DataSource")
                }
                if line.hasPrefix("}") { inDefaults = false }
                guard trimmed.hasPrefix("public "), !trimmed.contains(" override "), !inDefaults else { continue }
                checked += 1
                var doc: [String] = []
                var cursor = index - 1
                while cursor >= 0 {
                    let above = lines[cursor].trimmingCharacters(in: .whitespaces)
                    if above.hasPrefix("///") {
                        doc.append(above)
                    } else if !above.hasPrefix("@") {
                        break
                    }
                    cursor -= 1
                }
                let text = doc.joined(separator: " ")
                if !text.contains("`NS") && !text.contains("*Deviation") {
                    unexplained.append("\(file.lastPathComponent): \(trimmed)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 20, "found too few public members; the parser is broken")
        XCTAssertTrue(
            unexplained.isEmpty,
            "public members naming no AppKit counterpart and no deviation:\n" + unexplained.joined(separator: "\n"))
    }
}
