import XCTest

@testable import AgentSDK

final class JSONValueTests: XCTestCase {
    func testDecodesEveryKindAndRoundTrips() throws {
        let json = #"{"a":null,"b":true,"c":1.5,"d":"x","e":[1,"y"],"f":{"g":2}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(
            value,
            ["a": nil, "b": true, "c": 1.5, "d": "x", "e": [1, "y"], "f": ["g": 2]])
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(again, value)
    }

    func testIntegralNumbersEncodeWithoutFraction() throws {
        let data = try JSONEncoder().encode(JSONValue.array([3, 2.5]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[3,2.5]")
    }

    func testAccessors() {
        let value: JSONValue = ["n": 42, "s": "hi", "list": [true], "obj": ["k": "v"]]
        XCTAssertEqual(value["n"]?.intValue, 42)
        XCTAssertEqual(value["n"]?.doubleValue, 42)
        XCTAssertEqual(value["s"]?.stringValue, "hi")
        XCTAssertEqual(value["list"]?[0]?.boolValue, true)
        XCTAssertNil(value["list"]?[5])
        XCTAssertEqual(value["obj"]?["k"], "v")
        XCTAssertNil(value["missing"])
        XCTAssertNil(value["s"]?["k"])
        XCTAssertNil(JSONValue.number(1.5).intValue)
    }

    func testDecodeIntoOwnType() throws {
        struct Point: Decodable, Equatable { let x: Int }
        let value: JSONValue = ["x": 3]
        XCTAssertEqual(try value.decode(Point.self), Point(x: 3))
    }
}
