import Foundation
import XCTest

/// Every requirement in `SPEC.md` is proved by a test whose name carries its ID
/// (SPEC §13, "Traceability").
///
/// Reads the files themselves: the spec from the package root, the test
/// sources from `Tests/`. A requirement with no test fails here, by ID.
final class SpecCoverageTests: XCTestCase {

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testEveryRequirementHasATest() throws {
        let spec = try String(contentsOf: Self.packageRoot.appendingPathComponent("SPEC.md"), encoding: .utf8)
        let required = Set(Self.matches(of: #"\*\*([A-Z][0-9]+):"#, in: spec))
        XCTAssertFalse(required.isEmpty, "no requirement IDs found in SPEC.md")

        let testsDirectory = Self.packageRoot.appendingPathComponent("Tests")
        let files =
            FileManager.default.enumerator(at: testsDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var proved = Set<String>()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            proved.formUnion(Self.matches(of: #"func test([A-Z][0-9]+)_"#, in: source))
        }

        let missing = required.subtracting(proved).sorted()
        XCTAssertTrue(missing.isEmpty, "requirements without a test: \(missing.joined(separator: ", "))")
        let unknown = proved.subtracting(required).sorted()
        XCTAssertTrue(
            unknown.isEmpty, "tests naming IDs that SPEC.md doesn't define: \(unknown.joined(separator: ", "))")
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
