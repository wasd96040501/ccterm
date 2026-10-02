import XCTest

@testable import AgentSDK

/// The wire shapes the live-session design rests on (protocol.md): the advisor's
/// two blocks, the fields a transcript records per turn, the session title,
/// and `initialize`'s extras. Synthetic lines shaped like CLI 2.1.286.
final class LiveProtocolDecodingTests: XCTestCase {
    private func decode(_ line: String, file: StaticString = #filePath, line number: UInt = #line) -> Message {
        guard let message = Message(jsonLine: Data(line.utf8)) else {
            XCTFail("line did not decode", file: file, line: number)
            return .unknown(.null)
        }
        return message
    }

    private func block(_ json: String) throws -> ContentBlock {
        try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
    }

    // MARK: - The advisor

    func testServerToolUse() throws {
        XCTAssertEqual(
            try block(#"{"type":"server_tool_use","id":"srvtoolu_1","name":"advisor","input":{}}"#),
            .serverToolUse(ServerToolUseBlock(id: "srvtoolu_1", name: "advisor")))
    }

    func testAdvisorResultShapes() throws {
        let cases: [(String, AdvisorToolResultBlock.Content)] = [
            (
                #"{"type":"advisor_result","text":"Check the lock order.","stop_reason":"end_turn"}"#,
                .result(text: "Check the lock order.", stopReason: "end_turn")
            ),
            (#"{"type":"advisor_result","text":"Declined."}"#, .result(text: "Declined.", stopReason: nil)),
            (#"{"type":"advisor_redacted_result","encrypted_content":"EqQB"}"#, .redacted),
            (#"{"type":"advisor_tool_result_error","error_code":"overloaded"}"#, .error(code: "overloaded")),
        ]
        for (content, expected) in cases {
            let decoded = try block(
                #"{"type":"advisor_tool_result","tool_use_id":"srvtoolu_1","content":\#(content)}"#)
            XCTAssertEqual(
                decoded, .advisorToolResult(AdvisorToolResultBlock(toolUseID: "srvtoolu_1", content: expected)),
                content)
        }
    }

    func testAnAdvisorResultInAnUnknownShapeKeepsItsJSON() throws {
        let decoded = try block(
            #"{"type":"advisor_tool_result","tool_use_id":"s","content":{"type":"advisor_future","x":1}}"#)
        XCTAssertEqual(
            decoded,
            .advisorToolResult(
                AdvisorToolResultBlock(toolUseID: "s", content: .unknown(["type": "advisor_future", "x": 1]))))
        // No content at all is still the block, with nothing readable.
        guard case .advisorToolResult(let bare) = try block(#"{"type":"advisor_tool_result","tool_use_id":"s"}"#)
        else { return XCTFail("not an advisor result") }
        XCTAssertEqual(bare.content, .unknown(.null))
        // A call without an id can't be matched to its answer: it stays raw.
        guard case .unknown(let type, _) = try block(#"{"type":"server_tool_use","name":"advisor"}"#) else {
            return XCTFail("not unknown")
        }
        XCTAssertEqual(type, "server_tool_use")
    }

    func testAdvisorBlocksRoundTrip() throws {
        let blocks: [ContentBlock] = [
            .serverToolUse(ServerToolUseBlock(id: "s1", name: "advisor")),
            .advisorToolResult(
                AdvisorToolResultBlock(toolUseID: "s1", content: .result(text: "Hi", stopReason: "refusal"))),
            .advisorToolResult(AdvisorToolResultBlock(toolUseID: "s1", content: .result(text: "Hi", stopReason: nil))),
            .advisorToolResult(AdvisorToolResultBlock(toolUseID: "s1", content: .redacted)),
            .advisorToolResult(AdvisorToolResultBlock(toolUseID: "s1", content: .error(code: "unavailable"))),
            .advisorToolResult(AdvisorToolResultBlock(toolUseID: "s1", content: .unknown(["type": "future"]))),
        ]
        for original in blocks {
            let data = try JSONEncoder().encode(original)
            XCTAssertEqual(try JSONDecoder().decode(ContentBlock.self, from: data), original)
        }
        XCTAssertEqual(
            blocks[1].jsonValue["content"],
            ["type": "advisor_result", "text": "Hi", "stop_reason": "refusal"])
        XCTAssertEqual(
            blocks[4].jsonValue["content"], ["type": "advisor_tool_result_error", "error_code": "unavailable"])
    }

    func testTheAdvisorsHalvesLiveInOneAssistantMessage() {
        let message = decode(
            #"{"type":"assistant","uuid":"a1","session_id":"s","advisorModel":"claude-opus-5","effort":"high","message":{"id":"m1","model":"claude-sonnet-5","role":"assistant","content":[{"type":"server_tool_use","id":"srv1","name":"advisor","input":{}},{"type":"advisor_tool_result","tool_use_id":"srv1","content":{"type":"advisor_redacted_result","encrypted_content":"x"}}]}}"#
        )
        guard case .assistant(let a) = message else { return XCTFail("\(message)") }
        XCTAssertEqual(a.advisorModel, "claude-opus-5")
        XCTAssertEqual(a.effort, .high)
        XCTAssertEqual(a.content.count, 2)
        XCTAssertEqual(a.content[0], .serverToolUse(ServerToolUseBlock(id: "srv1", name: "advisor")))
        XCTAssertEqual(
            a.content[1], .advisorToolResult(AdvisorToolResultBlock(toolUseID: "srv1", content: .redacted)))
    }

    // MARK: - What the transcript records per turn

    func testAssistantWithoutEffortOrAdvisorReadsNil() {
        let message = decode(
            #"{"type":"assistant","uuid":"a1","session_id":"s","effort":"turbo","message":{"id":"m1","model":"x","role":"assistant","content":[{"type":"text","text":"hi"}]}}"#
        )
        guard case .assistant(let a) = message else { return XCTFail("\(message)") }
        XCTAssertNil(a.effort, "an effort this SDK doesn't know reads as absent")
        XCTAssertNil(a.advisorModel)
    }

    func testUserPermissionModeAndPastedImages() {
        let message = decode(
            #"{"type":"user","uuid":"u1","sessionId":"s","permissionMode":"acceptEdits","imagePasteIds":[2,3],"message":{"role":"user","content":[{"type":"text","text":"[Image #2] and [Image #3]"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"BB=="}}]}}"#
        )
        guard case .user(let u) = message else { return XCTFail("\(message)") }
        XCTAssertEqual(u.permissionMode, .acceptEdits)
        XCTAssertEqual(u.imagePasteIDs, [2, 3])
        XCTAssertEqual(u.content.count, 3)
        XCTAssertEqual(u.kind, .prompt)
    }

    func testUserWithoutThoseFieldsHasDefaults() {
        let message = decode(
            #"{"type":"user","uuid":"u1","session_id":"s","message":{"role":"user","content":"hi"}}"#)
        guard case .user(let u) = message else { return XCTFail("\(message)") }
        XCTAssertNil(u.permissionMode)
        XCTAssertEqual(u.imagePasteIDs, [])
    }

    // MARK: - System

    func testSessionTitleChanged() {
        let message = decode(
            #"{"type":"system","subtype":"session_title_changed","title":"Fix the build","uuid":"x","session_id":"s"}"#
        )
        XCTAssertEqual(message, .system(.sessionTitleChanged(title: "Fix the build")))
    }

    func testSessionTitleWithoutATitleStaysOther() {
        let message = decode(#"{"type":"system","subtype":"session_title_changed","session_id":"s"}"#)
        guard case .system(.other(let subtype, _)) = message else { return XCTFail("\(message)") }
        XCTAssertEqual(subtype, "session_title_changed")
    }

    // MARK: - initialize

    func testInitializationExtras() throws {
        let json = """
            {"commands":[],"agents":[],"output_style":"default","available_output_styles":["default"],
             "models":[{"value":"default","resolvedModel":"claude-opus-5","displayName":"Default","description":"d",
                        "supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],
                        "supportsFastMode":true}],
             "unavailable_models":[{"value":"zdr","displayName":"ZDR","description":"Excluded by your org","disabled":true},
                                   {"value":"odd"}],
             "account":{"email":"a@b.c","apiProvider":"bedrock"},
             "current_model":"claude-opus-5","current_permission_mode":"plan","session_state":"requires_action",
             "fast_mode_state":"cooldown","fast_mode_disabled_reason":"rate_limit","pid":1}
            """
        let result = try JSONDecoder().decode(InitializationResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.models.count, 1)
        XCTAssertEqual(result.models[0].resolvedModel, "claude-opus-5")
        XCTAssertFalse(result.models[0].isDisabled)
        XCTAssertEqual(result.models[0].supportedEffortLevels, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(result.unavailableModels.map(\.value), ["zdr", "odd"])
        XCTAssertTrue(result.unavailableModels.allSatisfy(\.isDisabled), "listed as unselectable")
        XCTAssertEqual(result.currentModel, "claude-opus-5")
        XCTAssertEqual(result.currentPermissionMode, .plan)
        XCTAssertEqual(result.sessionState, "requires_action")
        XCTAssertEqual(result.fastModeState, "cooldown")
        XCTAssertEqual(result.fastModeDisabledReason, "rate_limit")
        XCTAssertEqual(result.account?.apiProvider, "bedrock")
    }

    func testInitializationWithoutExtrasIsEmptyNotFailing() throws {
        let result = try JSONDecoder().decode(InitializationResult.self, from: Data(#"{"models":[]}"#.utf8))
        XCTAssertEqual(result.unavailableModels, [])
        XCTAssertNil(result.sessionState)
        XCTAssertNil(result.currentModel)
        XCTAssertNil(result.currentPermissionMode)
    }
}
