import XCTest

@testable import AgentSDK

/// Stream-json lines shaped like real CLI 2.1.2xx output.
final class MessageDecodingTests: XCTestCase {
    private func decode(_ line: String, file: StaticString = #filePath, line number: UInt = #line) -> Message {
        guard let message = Message(jsonLine: Data(line.utf8)) else {
            XCTFail("line did not decode", file: file, line: number)
            return .unknown(.null)
        }
        return message
    }

    // MARK: - Assistant

    func testAssistantTextBlock() throws {
        let message = decode(
            #"{"type":"assistant","message":{"model":"claude-opus-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Hello"}],"stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":3635,"cache_read_input_tokens":43031,"output_tokens":3,"service_tier":"standard"}},"parent_tool_use_id":null,"session_id":"s1","uuid":"u1","timestamp":"2026-08-10T06:08:54.203Z","request_id":"req_1"}"#
        )
        guard case .assistant(let a) = message else { return XCTFail("\(message)") }
        XCTAssertEqual(a.uuid, "u1")
        XCTAssertEqual(a.sessionID, "s1")
        XCTAssertEqual(a.messageID, "msg_1")
        XCTAssertEqual(a.model, "claude-opus-5")
        XCTAssertEqual(a.content, [.text("Hello")])
        XCTAssertNil(a.stopReason)
        XCTAssertNil(a.parentToolUseID)
        XCTAssertEqual(a.usage?.totalInputTokens, 2 + 3635 + 43031)
        XCTAssertEqual(a.usage?.outputTokens, 3)
        XCTAssertFalse(a.isAborted)
        XCTAssertNotNil(a.timestamp)
    }

    func testAssistantToolUseAndThinking() {
        let toolUse = decode(
            #"{"type":"assistant","message":{"model":"m","id":"msg_2","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"},"caller":{"type":"direct"}}]},"parent_tool_use_id":"toolu_parent","session_id":"s","uuid":"u2"}"#
        )
        guard case .assistant(let a) = toolUse else { return XCTFail() }
        XCTAssertEqual(a.content, [.toolUse(ToolUseBlock(id: "toolu_1", name: "Bash", input: ["command": "ls"]))])
        XCTAssertEqual(a.parentToolUseID, "toolu_parent")

        let thinking = decode(
            #"{"type":"assistant","message":{"model":"m","id":"msg_3","content":[{"type":"thinking","thinking":"hmm","signature":"sig"},{"type":"redacted_thinking","data":"xyz"}]},"session_id":"s","uuid":"u3"}"#
        )
        guard case .assistant(let t) = thinking else { return XCTFail() }
        XCTAssertEqual(t.content, [.thinking("hmm"), .redactedThinking("xyz")])
    }

    func testAssistantStringContentAndUnknownBlock() {
        let message = decode(
            #"{"type":"assistant","message":{"model":"<synthetic>","id":"m","content":"plain"},"session_id":"s","uuid":"u","error":"rate_limit","aborted":true}"#
        )
        guard case .assistant(let a) = message else { return XCTFail() }
        XCTAssertEqual(a.content, [.text("plain")])
        XCTAssertEqual(a.error, "rate_limit")
        XCTAssertTrue(a.isAborted)

        let fallback = decode(
            #"{"type":"assistant","message":{"model":"m","id":"m","content":[{"type":"fallback","from":{"model":"a"},"to":{"model":"b"}}]},"session_id":"s","uuid":"u"}"#
        )
        guard case .assistant(let f) = fallback, case .unknown(let type, let raw) = f.content.first else {
            return XCTFail()
        }
        XCTAssertEqual(type, "fallback")
        XCTAssertEqual(raw["to"]?["model"], "b")
    }

    func testAssistantWithoutMessageDegradesToUnknown() {
        let message = decode(#"{"type":"assistant","uuid":"u","session_id":"s"}"#)
        guard case .unknown(let raw) = message else { return XCTFail("\(message)") }
        XCTAssertEqual(raw["uuid"], "u")
    }

    func testMalformedBlockDegradesOnlyThatBlock() {
        let message = decode(
            #"{"type":"assistant","message":{"model":"m","id":"m","content":[{"type":"text"},{"type":"text","text":"ok"}]},"session_id":"s","uuid":"u"}"#
        )
        guard case .assistant(let a) = message else { return XCTFail() }
        XCTAssertEqual(a.content.count, 2)
        if case .unknown(let type, _) = a.content[0] { XCTAssertEqual(type, "text") } else { XCTFail() }
        XCTAssertEqual(a.content[1], .text("ok"))
    }

    // MARK: - User

    func testUserPromptAndReplay() {
        let prompt = decode(#"{"type":"user","uuid":"p1","session_id":"s","message":{"role":"user","content":"hi"}}"#)
        guard case .user(let p) = prompt else { return XCTFail() }
        XCTAssertEqual(p.content, [.text("hi")])
        XCTAssertFalse(p.isReplay)
        XCTAssertNil(p.toolResult)

        let replay = decode(
            #"{"type":"user","message":{"role":"user","content":"hi"},"session_id":"s","parent_tool_use_id":null,"uuid":"p1","timestamp":"2026-08-10T06:04:21.595Z","isReplay":true,"origin":{"kind":"human"}}"#
        )
        guard case .user(let r) = replay else { return XCTFail() }
        XCTAssertTrue(r.isReplay)
        XCTAssertEqual(r.uuid, "p1")
        XCTAssertEqual(r.origin, "human")
    }

    func testUserToolResultSuccessAndError() {
        let ok = decode(
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"tool_reference","tool_name":"WebSearch"}]}]},"parent_tool_use_id":null,"session_id":"s","uuid":"u","tool_use_result":{"matches":["WebSearch"]}}"#
        )
        guard case .user(let u) = ok, let result = u.toolResult else { return XCTFail() }
        XCTAssertEqual(result.toolUseID, "toolu_1")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(u.toolUseResult?["matches"]?[0], "WebSearch")

        let error = decode(
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Exit code 1","is_error":true,"tool_use_id":"toolu_2"}]},"session_id":"s","uuid":"u","tool_use_result":"Error: Exit code 1"}"#
        )
        guard case .user(let e) = error else { return XCTFail() }
        XCTAssertEqual(e.toolResult?.content, [.text("Exit code 1")])
        XCTAssertEqual(e.toolResult?.isError, true)
        XCTAssertEqual(e.toolUseResult, "Error: Exit code 1")
    }

    func testDiskSpellingsDecodeToTheSameModel() {
        let disk = decode(
            #"{"type":"user","parentUuid":"p","isSidechain":false,"sessionId":"s","uuid":"u","isMeta":true,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"x"}]},"toolUseResult":{"k":1}}"#
        )
        guard case .user(let u) = disk else { return XCTFail() }
        XCTAssertEqual(u.sessionID, "s")
        XCTAssertTrue(u.isSynthetic)
        XCTAssertEqual(u.toolUseResult, ["k": 1])
    }

    // MARK: - Result

    func testResultSuccess() {
        let message = decode(
            #"{"type":"result","subtype":"success","is_error":false,"duration_ms":5000,"duration_api_ms":289149,"num_turns":20,"result":"Done","stop_reason":"end_turn","session_id":"s","total_cost_usd":0.95,"usage":{"input_tokens":53,"output_tokens":10391},"modelUsage":{"claude-opus-5":{"inputTokens":53,"outputTokens":10391,"cacheReadInputTokens":248530,"cacheCreationInputTokens":29929,"webSearchRequests":0,"costUSD":0.68,"contextWindow":1000000,"maxOutputTokens":64000,"canonicalModel":"claude-opus-5"}},"permission_denials":[{"tool_name":"Bash","tool_use_id":"t","tool_input":{"command":"rm"}}],"terminal_reason":"completed","uuid":"r1","user_message_uuids":["p1","p2"],"queued_turn_count":1}"#
        )
        guard case .result(let r) = message else { return XCTFail() }
        XCTAssertEqual(r.subtype, .success)
        XCTAssertFalse(r.isError)
        XCTAssertEqual(r.result, "Done")
        XCTAssertEqual(r.numTurns, 20)
        XCTAssertEqual(r.totalCostUSD, 0.95)
        XCTAssertEqual(r.modelUsage["claude-opus-5"]?.contextWindow, 1_000_000)
        XCTAssertEqual(r.permissionDenials.first?.toolInput["command"], "rm")
        XCTAssertEqual(r.userMessageUUIDs, ["p1", "p2"])
        XCTAssertEqual(r.queuedTurnCount, 1)
        XCTAssertEqual(r.terminalReason, "completed")
    }

    func testResultInterruptedAndUnknownSubtype() {
        let interrupted = decode(
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["[ede_diagnostic] x"],"terminal_reason":"aborted_streaming","session_id":"s","uuid":"r","user_message_uuid":"p9"}"#
        )
        guard case .result(let r) = interrupted else { return XCTFail() }
        XCTAssertEqual(r.subtype, .errorDuringExecution)
        XCTAssertTrue(r.isError)
        XCTAssertEqual(r.errors.count, 1)
        XCTAssertEqual(r.userMessageUUIDs, ["p9"])

        let future = decode(#"{"type":"result","subtype":"error_new_kind","session_id":"s","uuid":"r"}"#)
        guard case .result(let f) = future else { return XCTFail() }
        XCTAssertEqual(f.subtype.rawValue, "error_new_kind")
        XCTAssertTrue(f.isError)
    }

    // MARK: - System

    func testSystemInit() {
        let message = decode(
            #"{"type":"system","subtype":"init","cwd":"/p","session_id":"s","tools":["Task","Bash"],"mcp_servers":[{"name":"x","status":"connected"},{"bogus":1}],"model":"claude-opus-5[1m]","permissionMode":"auto","slash_commands":["a"],"apiKeySource":"none","claude_code_version":"2.1.223","output_style":"default","agents":["claude"],"skills":["s"],"uuid":"u"}"#
        )
        guard case .system(.initialized(let i)) = message else { return XCTFail("\(message)") }
        XCTAssertEqual(i.sessionID, "s")
        XCTAssertEqual(i.permissionMode, .auto)
        XCTAssertEqual(i.tools, ["Task", "Bash"])
        XCTAssertEqual(i.mcpServers.map(\.name), ["x"])
        XCTAssertEqual(i.claudeCodeVersion, "2.1.223")
    }

    func testSystemSignals() {
        XCTAssertEqual(
            decode(#"{"type":"system","subtype":"status","status":"requesting","uuid":"u","session_id":"s"}"#),
            .system(.status(.init(status: "requesting", permissionMode: nil))))
        XCTAssertEqual(
            decode(
                #"{"type":"system","subtype":"status","status":null,"permissionMode":"plan","uuid":"u","session_id":"s"}"#
            ),
            .system(.status(.init(status: nil, permissionMode: .plan))))
        XCTAssertEqual(
            decode(
                #"{"type":"system","subtype":"compact_boundary","session_id":"s","uuid":"u","compact_metadata":{"trigger":"manual","pre_tokens":459814,"post_tokens":14757}}"#
            ),
            .system(.compactBoundary(.init(trigger: "manual", preTokens: 459_814, postTokens: 14757))))
        XCTAssertEqual(
            decode(
                #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":608,"error_status":null,"error":"unknown","session_id":"s","uuid":"u"}"#
            ),
            .system(.apiRetry(.init(attempt: 1, maxRetries: 10, retryDelayMS: 608, errorStatus: nil, error: "unknown")))
        )
        XCTAssertEqual(
            decode(
                #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"estimated_tokens_delta":50,"uuid":"u","session_id":"s"}"#
            ),
            .system(.thinkingTokens(.init(estimatedTokens: 50, estimatedTokensDelta: 50))))
        XCTAssertEqual(
            decode(
                #"{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"t","decision_reason":"x","message":"no","uuid":"u","session_id":"s"}"#
            ),
            .system(.permissionDenied(.init(toolName: "Bash", toolUseID: "t", message: "no", agentID: nil))))
    }

    func testSystemTasks() {
        XCTAssertEqual(
            decode(
                #"{"type":"system","subtype":"task_started","task_id":"b9","tool_use_id":"t","description":"Fetch","task_type":"local_bash","uuid":"u","session_id":"s"}"#
            ),
            .system(
                .taskStarted(
                    .init(
                        taskID: "b9", toolUseID: "t", description: "Fetch", taskType: "local_bash", subagentType: nil,
                        prompt: nil))))
        XCTAssertEqual(
            decode(
                #"{"type":"system","subtype":"task_progress","task_id":"a6","tool_use_id":"t","description":"Read","usage":{"total_tokens":51298,"tool_uses":1,"duration_ms":2881},"last_tool_name":"Read","uuid":"u","session_id":"s"}"#
            ),
            .system(
                .taskProgress(
                    .init(
                        taskID: "a6", toolUseID: "t", description: "Read", totalTokens: 51298, toolUses: 1,
                        durationMS: 2881, lastToolName: "Read", summary: nil))))
        XCTAssertEqual(
            decode(
                #"{"type":"system","subtype":"task_updated","task_id":"b2","patch":{"status":"completed","end_time":1},"uuid":"u","session_id":"s"}"#
            ),
            .system(
                .taskUpdated(
                    .init(taskID: "b2", status: "completed", description: nil, error: nil, isBackgrounded: nil))))
        XCTAssertEqual(
            decode(
                #"{"type":"system","subtype":"task_notification","task_id":"b9","tool_use_id":"t","status":"completed","output_file":"/o","summary":"done","uuid":"u","session_id":"s"}"#
            ),
            .system(
                .taskNotification(
                    .init(taskID: "b9", toolUseID: "t", status: "completed", outputFile: "/o", summary: "done"))))
        XCTAssertEqual(
            decode(
                #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b2","task_type":"local_bash","description":"Deploy"}],"uuid":"u","session_id":"s"}"#
            ),
            .system(.backgroundTasksChanged([.init(taskID: "b2", taskType: "local_bash", description: "Deploy")])))
        XCTAssertEqual(
            decode(
                #"{"type":"system","subtype":"commands_changed","commands":[{"name":"deploy","description":"d","argumentHint":"<x>"}],"uuid":"u","session_id":"s"}"#
            ),
            .system(.commandsChanged([.init(name: "deploy", description: "d", argumentHint: "<x>")])))
    }

    func testUnknownAndMalformedSystemSubtypesKeepRawJSON() {
        let vcs = decode(
            #"{"type":"system","subtype":"vcs_state_changed","kind":"push","branch":"main","uuid":"u","session_id":"s"}"#
        )
        guard case .system(.other(let subtype, let raw)) = vcs else { return XCTFail() }
        XCTAssertEqual(subtype, "vcs_state_changed")
        XCTAssertEqual(raw["branch"], "main")

        let broken = decode(#"{"type":"system","subtype":"task_started","uuid":"u"}"#)
        guard case .system(.other(let brokenSubtype, _)) = broken else { return XCTFail() }
        XCTAssertEqual(brokenSubtype, "task_started")
    }

    // MARK: - Stream events

    func testStreamEvents() {
        func event(_ json: String) -> StreamEvent.Event? {
            let line =
                #"{"type":"stream_event","event":"# + json
                + #","session_id":"s","parent_tool_use_id":null,"uuid":"u"}"#
            guard case .streamEvent(let e) = decode(line) else { return nil }
            return e.event
        }
        XCTAssertEqual(
            event(#"{"type":"message_start","message":{"model":"claude-opus-5","id":"msg_1","content":[]}}"#),
            .messageStart(messageID: "msg_1", model: "claude-opus-5"))
        XCTAssertEqual(
            event(#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            .contentBlockStart(index: 1, block: .text("")))
        XCTAssertEqual(
            event(
                #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t","name":"Bash","input":{}}}"#
            ),
            .contentBlockStart(index: 1, block: .toolUse(.init(id: "t", name: "Bash", input: [:]))))
        XCTAssertEqual(
            event(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi"}}"#),
            .contentBlockDelta(index: 1, delta: .text("Hi")))
        XCTAssertEqual(
            event(
                #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"a","estimated_tokens":50}}"#
            ),
            .contentBlockDelta(index: 0, delta: .thinking("a")))
        XCTAssertEqual(
            event(
                #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"a"}}"#),
            .contentBlockDelta(index: 1, delta: .inputJSON(#"{"a"#)))
        XCTAssertEqual(
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#),
            .contentBlockDelta(index: 0, delta: .signature("sig")))
        XCTAssertEqual(event(#"{"type":"content_block_stop","index":0}"#), .contentBlockStop(index: 0))
        XCTAssertEqual(
            event(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":395}}"#),
            .messageDelta(stopReason: "tool_use", usage: Usage(outputTokens: 395)))
        XCTAssertEqual(event(#"{"type":"message_stop"}"#), .messageStop)
        XCTAssertEqual(event(#"{"type":"ping"}"#), .ping)
        XCTAssertEqual(event(#"{"type":"future_event","x":1}"#), .unknown(["type": "future_event", "x": 1]))
        XCTAssertEqual(
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"citations_delta"}}"#),
            .contentBlockDelta(index: 0, delta: .unknown(["type": "citations_delta"])))
    }

    // MARK: - Other kinds

    func testSmallKinds() {
        XCTAssertEqual(
            decode(
                #"{"type":"tool_progress","tool_use_id":"toolu_A-heartbeat-1","tool_name":"Bash","parent_tool_use_id":"toolu_A","elapsed_time_seconds":30,"heartbeat":true,"session_id":"s","uuid":"u"}"#
            ),
            .toolProgress(
                .init(toolUseID: "toolu_A", toolName: "Bash", parentToolUseID: nil, elapsedTimeSeconds: 30, taskID: nil)
            ))
        XCTAssertEqual(
            decode(
                #"{"type":"tool_progress","tool_use_id":"toolu_B","tool_name":"Read","parent_tool_use_id":"toolu_agent","elapsed_time_seconds":4,"session_id":"s","uuid":"u"}"#
            ),
            .toolProgress(
                .init(
                    toolUseID: "toolu_B", toolName: "Read", parentToolUseID: "toolu_agent", elapsedTimeSeconds: 4,
                    taskID: nil)))
        XCTAssertEqual(
            decode(
                #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1786347600,"rateLimitType":"five_hour","isUsingOverage":false},"uuid":"u","session_id":"s"}"#
            ),
            .rateLimit(
                .init(
                    status: "allowed", resetsAt: Date(timeIntervalSince1970: 1_786_347_600), rateLimitType: "five_hour",
                    utilization: nil)))
        XCTAssertEqual(
            decode(#"{"type":"command_lifecycle","command_uuid":"c","state":"queued","uuid":"u","session_id":"s"}"#),
            .commandLifecycle(.init(commandUUID: "c", state: .queued)))
        XCTAssertEqual(
            decode(#"{"type":"prompt_suggestion","suggestion":"run the tests","uuid":"u","session_id":"s"}"#),
            .promptSuggestion("run the tests"))
        XCTAssertTrue(CommandLifecycle.State.cancelled.isTerminal)
        XCTAssertFalse(CommandLifecycle.State.started.isTerminal)
    }

    func testUnknownTypeAndInvalidLines() {
        XCTAssertEqual(
            decode(#"{"type":"conversation_reset","new_conversation_id":"x"}"#),
            .unknown(["type": "conversation_reset", "new_conversation_id": "x"]))
        XCTAssertEqual(decode(#"{"no_type":true}"#), .unknown(["no_type": true]))
        XCTAssertNil(Message(jsonLine: Data("not json".utf8)))
        XCTAssertNil(Message(jsonLine: Data("[1,2]".utf8)))
        XCTAssertNil(Message(jsonLine: Data()))
    }
}
