import XCTest

@testable import AgentSDK

/// The stdin line a `UserInput` becomes.
final class UserInputTests: XCTestCase {

    /// Text-only prompts go as a plain string, as the CLI's own SDK sends
    /// them — the form the CLI parses slash commands out of.
    func testTextOnlyPromptIsAPlainString() {
        let line = UserInput("/compact", uuid: "u1").jsonValue
        XCTAssertEqual(line["type"], "user")
        XCTAssertEqual(line["uuid"], "u1")
        XCTAssertEqual(line["message"]?["role"], "user")
        XCTAssertEqual(line["message"]?["content"], "/compact")
        XCTAssertEqual(line["parent_tool_use_id"], .null)
        XCTAssertNil(line["priority"])
        XCTAssertNil(line["plan_content"])
    }

    func testImagePromptIsABlockArray() {
        let input = UserInput(
            uuid: "u2",
            content: [.image(ImageBlock(data: Data([1, 2, 3]), mediaType: "image/png")), .text("what is this?")])
        let content = input.jsonValue["message"]?["content"]
        XCTAssertEqual(content?.arrayValue?.count, 2)
        XCTAssertEqual(content?[0]?["type"], "image")
        XCTAssertEqual(content?[0]?["source"]?["type"], "base64")
        XCTAssertEqual(content?[0]?["source"]?["media_type"], "image/png")
        XCTAssertEqual(content?[0]?["source"]?["data"], .string(Data([1, 2, 3]).base64EncodedString()))
        XCTAssertEqual(content?[1]?["type"], "text")
        XCTAssertEqual(content?[1]?["text"], "what is this?")
    }

    func testMultipleTextBlocksStayAnArray() {
        let content = UserInput(content: [.text("a"), .text("b")]).jsonValue["message"]?["content"]
        XCTAssertEqual(content?.arrayValue?.count, 2)
    }

    func testPriorityAndPlanContent() {
        var input = UserInput("go", priority: .now)
        input.planContent = "1. do it"
        let line = input.jsonValue
        XCTAssertEqual(line["priority"], "now")
        XCTAssertEqual(line["plan_content"], "1. do it")
    }
}
