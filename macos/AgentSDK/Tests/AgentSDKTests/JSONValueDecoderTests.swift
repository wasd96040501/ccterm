import Foundation
import XCTest

@testable import AgentSDK

/// `JSONValue.decode` reads a type straight from the tree; it must read what
/// the text round trip through `JSONDecoder` read — the same values, and the
/// same errors at the same coding paths (save that a number that doesn't fit
/// names its key).
final class JSONValueDecoderTests: XCTestCase {
    private struct Everything: Decodable, Equatable {
        enum Mode: String, Decodable { case plan, edit }
        struct Hunk: Decodable, Equatable {
            var start: Int
            var lines: [String]
        }
        var name: String
        var count: Int
        var small: UInt8
        var ratio: Double
        var single: Float
        var flag: Bool
        var mode: Mode
        var hunks: [Hunk]
        var grid: [[Int]]
        var totals: [String: Int]
        var missing: String?
        var null: Int?
        var optionals: [Int?]
        var url: URL
        var data: Data
        var date: Date
        var decimal: Decimal
    }

    private static let everything = #"""
        {"name":"A.swift","count":5.0,"small":255,"ratio":0.25,"single":1.5,"flag":true,"mode":"edit",
         "hunks":[{"start":4,"lines":[" x","-a","+b"]},{"start":40,"lines":[]}],
         "grid":[[1,2],[3]],"totals":{"a":1,"b":2},"null":null,"optionals":[1,null,3],
         "url":"https://example.com/a?b=c","data":"aGVsbG8=","date":1000.5,"decimal":12.5,"extra":{"ignored":[1]}}
        """#

    private func value(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    /// What `decode` did before: the tree written out and read back.
    private func roundTrip<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testReadsWhatTheRoundTripRead() throws {
        let tree = try value(Self.everything)
        let direct = try tree.decode(Everything.self)
        XCTAssertEqual(direct, try roundTrip(Everything.self, tree))
        XCTAssertEqual(direct.count, 5, "a whole number reads as an Int")
        XCTAssertEqual(direct.data, Data("hello".utf8))
        XCTAssertNil(direct.missing)
        XCTAssertEqual(direct.optionals, [1, nil, 3])
    }

    func testFailsWhereTheRoundTripFailedAtTheSamePlace() throws {
        // A number that doesn't fit is the one difference: JSONDecoder's
        // error has an empty path, this one names the key.
        let cases: [(json: String, what: String, path: String?)] = [
            (#"{"count":1}"#, "a missing key", nil),
            (#"{"name":null}"#, "a null where a value belongs", nil),
            (#"{"name":3}"#, "a number where a string belongs", nil),
            (#"{"name":"a","count":1.5}"#, "a fraction into an Int", "count"),
            (#"{"name":"a","count":1,"small":256}"#, "a number out of UInt8's range", "small"),
            (#"{"name":"a","count":1,"small":1,"ratio":0,"single":0,"flag":1}"#, "a number where a Bool belongs", nil),
            (
                #"{"name":"a","count":1,"small":1,"ratio":0,"single":0,"flag":true,"mode":"edit","hunks":[{"start":1,"lines":[2]}]}"#,
                "a number inside a nested array", nil
            ),
        ]
        for (json, what, path) in cases {
            let tree = try value(json)
            let direct = Self.error { try tree.decode(Everything.self) }
            let old = Self.error { try self.roundTrip(Everything.self, tree) }
            XCTAssertNotNil(direct, what)
            XCTAssertEqual(direct?.kind, old?.kind, what)
            XCTAssertEqual(direct?.path, path ?? old?.path, what)
        }
    }

    /// A `DecodingError`'s case and coding path, the parts a caller reads.
    private static func error(_ body: () throws -> Any) -> (kind: String, path: String)? {
        do {
            _ = try body()
            return nil
        } catch let error as DecodingError {
            let (kind, context): (String, DecodingError.Context) =
                switch error {
                case .keyNotFound(_, let context): ("keyNotFound", context)
                case .valueNotFound(_, let context): ("valueNotFound", context)
                case .typeMismatch(_, let context): ("typeMismatch", context)
                case .dataCorrupted(let context): ("dataCorrupted", context)
                @unknown default: ("unknown", DecodingError.Context(codingPath: [], debugDescription: ""))
                }
            return (
                kind, context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            )
        } catch {
            return ("other", "")
        }
    }
}
