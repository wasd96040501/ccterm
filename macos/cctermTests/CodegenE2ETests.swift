import XCTest
import AgentSDK

// MARK: - Helpers

private func camelToSnake(_ s: String) -> String {
    var result = ""
    let chars = Array(s)
    for (i, c) in chars.enumerated() {
        if c.isUppercase {
            if i > 0 && chars[i-1].isLowercase { result += "_" }
            else if i > 0 && i+1 < chars.count && chars[i-1].isUppercase && chars[i+1].isLowercase { result += "_" }
        }
        result += String(c).lowercased()
    }
    return result
}

private func normalizeForComparison(_ json: Any) -> Any {
    if let dict = json as? [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            if value is NSNull { continue }
            let snakeKey = key.hasPrefix("_") ? key : camelToSnake(key)
            result[snakeKey] = normalizeForComparison(value)
        }
        return result
    }
    if let arr = json as? [Any] {
        return arr.map { normalizeForComparison($0) }
    }
    return json
}

// MARK: - DiffCollector

private struct DiffCollector {
    var missingKeys: [String: Int] = [:]
    var extraKeys: [String: Int] = [:]
    var valueMismatches: [String: Int] = [:]

    mutating func compare(original: Any, typed: Any, path: String) {
        if let origDict = original as? [String: Any],
           let typedDict = typed as? [String: Any] {
            for key in origDict.keys {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                if let typedVal = typedDict[key] {
                    compare(original: origDict[key]!, typed: typedVal, path: childPath)
                } else {
                    missingKeys[childPath, default: 0] += 1
                }
            }
            for key in typedDict.keys where origDict[key] == nil {
                extraKeys[(path.isEmpty ? key : "\(path).\(key)"), default: 0] += 1
            }
            return
        }

        if let origArr = original as? [Any], let typedArr = typed as? [Any] {
            let childPath = "\(path)[]"
            for i in 0..<max(origArr.count, typedArr.count) {
                if i < origArr.count && i < typedArr.count {
                    compare(original: origArr[i], typed: typedArr[i], path: childPath)
                } else if i < origArr.count {
                    missingKeys["\(childPath)[overflow]", default: 0] += 1
                } else {
                    extraKeys["\(childPath)[overflow]", default: 0] += 1
                }
            }
            return
        }

        if !(original as AnyObject).isEqual(typed as AnyObject) {
            valueMismatches[path, default: 0] += 1
        }
    }
}

// MARK: - TypedJSONReport

private struct TypedJSONReport {
    var parseErrors = 0
    var perVariant: [String: VariantStats] = [:]
    var globalDiffs = DiffCollector()

    struct VariantStats {
        var total = 0
        var exactMatch = 0
        var diffs = DiffCollector()
    }

    mutating func record(variant: String, original: Any, typed: Any) {
        let normOrig = normalizeForComparison(original)
        let normTyped = normalizeForComparison(typed)

        var stats = perVariant[variant] ?? VariantStats()
        stats.total += 1

        if (normOrig as AnyObject).isEqual(normTyped as AnyObject) {
            stats.exactMatch += 1
        } else {
            stats.diffs.compare(original: normOrig, typed: normTyped, path: "")
            globalDiffs.compare(original: normOrig, typed: normTyped, path: "")
        }
        perVariant[variant] = stats
    }

    func write(to path: String) {
        var lines: [String] = []
        lines.append("=== Typed JSON E2E Summary ===")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        let total = perVariant.values.reduce(0) { $0 + $1.total }
        lines.append("Total records: \(total)")
        lines.append("Parse errors: \(parseErrors)")
        lines.append("")

        lines.append("Per-variant breakdown:")
        for (name, stats) in perVariant.sorted(by: { $0.value.total > $1.value.total }) {
            let pct = stats.total > 0 ? Double(stats.exactMatch) / Double(stats.total) * 100 : 0
            let diff = stats.total - stats.exactMatch
            lines.append(String(format: "  %-25s %5d total  %5d exact (%5.1f%%)  %5d diff",
                                (name as NSString).utf8String!, stats.total, stats.exactMatch, pct, diff))
        }
        lines.append("")

        lines.append("Top missing keys (original has, typed missing) — top 30:")
        let topMissing = globalDiffs.missingKeys.sorted { $0.value > $1.value }.prefix(30)
        for (path, count) in topMissing {
            lines.append("  \(path): \(count) occurrences")
        }
        lines.append("")

        lines.append("Top value mismatches (same key, different value) — top 20:")
        let topMismatch = globalDiffs.valueMismatches.sorted { $0.value > $1.value }.prefix(20)
        for (path, count) in topMismatch {
            lines.append("  \(path): \(count) occurrences")
        }

        if !globalDiffs.extraKeys.isEmpty {
            lines.append("")
            lines.append("Extra keys (typed has, original missing) — top 10:")
            let topExtra = globalDiffs.extraKeys.sorted { $0.value > $1.value }.prefix(10)
            for (path, count) in topExtra {
                lines.append("  \(path): \(count) occurrences")
            }
        }

        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - JSONL Loading

private func loadAllJSONLRecords() -> [(file: String, line: Int, dict: [String: Any])] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let searchRoots = [
        home.appendingPathComponent(".claude/projects"),
        home.appendingPathComponent(".cache/ccterm/export"),
    ]
    var results: [(String, Int, [String: Any])] = []
    for root in searchRoots {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { continue }
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let content = String(data: data, encoding: .utf8) else { continue }
            for (i, line) in content.split(separator: "\n").enumerated() {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData),
                      let dict = json as? [String: Any] else { continue }
                results.append((fileURL.path, i + 1, dict))
            }
        }
    }
    return results
}

// MARK: - Tests

final class CodegenE2ETests: XCTestCase {

    private static var records: [(file: String, line: Int, dict: [String: Any])] = []

    override class func setUp() {
        super.setUp()
        records = loadAllJSONLRecords()
        NSLog("=== CodegenE2E: loaded %d JSONL records ===", records.count)
    }

    // MARK: Test 1 — Roundtrip

    func testRoundtrip() throws {
        let records = Self.records
        XCTAssertGreaterThan(records.count, 0, "No JSONL records found")

        var parseErrors = 0
        var roundtripFailures: [(file: String, line: Int)] = []

        for (file, line, dict) in records {
            do {
                let msg = try Message2(json: dict)
                let output = msg.toJSON()
                if !(output as AnyObject).isEqual(dict as AnyObject) {
                    roundtripFailures.append((file, line))
                }
            } catch {
                parseErrors += 1
            }
        }

        for f in roundtripFailures.prefix(10) {
            NSLog("=== ROUNDTRIP FAIL: %@:%d ===", f.file, f.line)
        }
        NSLog("=== Roundtrip: %d records, %d parse errors, %d failures ===",
              records.count, parseErrors, roundtripFailures.count)
        XCTAssertEqual(roundtripFailures.count, 0, "Roundtrip failures: \(roundtripFailures.count)")
    }

    // MARK: Test 2 — Typed JSON Summary

    func testTypedJSONSummary() throws {
        let records = Self.records
        XCTAssertGreaterThan(records.count, 0, "No JSONL records found")

        var report = TypedJSONReport()

        for (_, _, dict) in records {
            do {
                let msg = try Message2(json: dict)
                let typed = msg.toTypedJSON()
                let variant = dict["type"] as? String ?? dict["subtype"] as? String ?? "unknown"
                report.record(variant: variant, original: dict, typed: typed)
            } catch {
                report.parseErrors += 1
            }
        }

        let path = "/tmp/typed_json_summary.txt"
        report.write(to: path)
        NSLog("=== Typed JSON summary written to: %@ ===", path)
    }

    // MARK: Test 3 — Resolver roundtrip

    func testResolverRoundtrip() throws {
        let records = Self.records
        XCTAssertGreaterThan(records.count, 0, "No JSONL records found")

        let resolver = Message2Resolver()
        var resolvedCount = 0
        var unresolvedCount = 0
        var parseErrors = 0

        for (_, _, dict) in records {
            do {
                let msg = try resolver.resolve(dict)

                // Check if this is a user message with a tool_use_result
                if case .user(let user) = msg {
                    if let result = user.toolUseResult {
                        if case .object(let obj) = result {
                            switch obj {
                            case .unknown(let name, _, _):
                                if name == "unresolved" {
                                    unresolvedCount += 1
                                } else {
                                    // Has a tool name but didn't match a known variant
                                    resolvedCount += 1
                                }
                            default:
                                resolvedCount += 1
                            }
                        }
                    }
                }
            } catch {
                parseErrors += 1
            }
        }

        NSLog("=== Resolver: %d resolved, %d unresolved, %d parse errors ===",
              resolvedCount, unresolvedCount, parseErrors)
        // The resolver should resolve most tool results
        if resolvedCount + unresolvedCount > 0 {
            let resolvePct = Double(resolvedCount) / Double(resolvedCount + unresolvedCount) * 100
            NSLog("=== Resolver resolve rate: %.1f%% ===", resolvePct)
            XCTAssertGreaterThan(resolvedCount, 0, "Resolver should resolve at least some tool results")
        }
    }

    // MARK: Test 4 — Direct resolving via resolve(from:)

    func testDirectResolving() throws {
        let bashJson: [String: Any] = [
            "stdout": "hello world",
            "stderr": "",
            "interrupted": false,
            "is_image": false,
        ]

        // Create a ToolUse.Bash origin
        let toolUseJson: [String: Any] = [
            "type": "tool_use",
            "id": "toolu_123",
            "name": "Bash",
            "input": ["command": "echo hello"],
        ]
        let origin = try ToolUse(json: toolUseJson)

        // resolve(from:) should produce .Bash
        var obj = try ToolUseResultObject(json: bashJson)
        XCTAssertTrue(obj.isUnresolved)
        try obj.resolve(from: origin)
        if case .Bash(let bash, _) = obj {
            XCTAssertEqual(bash.stdout, "hello world")
            XCTAssertEqual(bash.stderr, "")
        } else {
            XCTFail("Expected .Bash, got \(obj)")
        }

        // Fallback init should produce .unknown(unresolved)
        let fallback = try ToolUseResultObject(json: bashJson)
        if case .unknown(let name, _, _) = fallback {
            XCTAssertEqual(name, "unresolved")
        } else {
            XCTFail("Expected .unknown(unresolved), got \(fallback)")
        }
    }

    // MARK: Test 5 — Origin access after resolve

    func testOriginAccess() throws {
        let bashJson: [String: Any] = [
            "stdout": "hello",
            "stderr": "",
            "interrupted": false,
            "is_image": false,
        ]
        let toolUseJson: [String: Any] = [
            "type": "tool_use",
            "id": "toolu_456",
            "name": "Bash",
            "input": ["command": "echo hello"],
        ]
        let origin = try ToolUse(json: toolUseJson)

        var obj = try ToolUseResultObject(json: bashJson)
        XCTAssertNil(obj.toolUse)
        try obj.resolve(from: origin)
        XCTAssertNotNil(obj.toolUse)
        if case .Bash = obj.toolUse {
            // expected
        } else {
            XCTFail("Expected toolUse to be .Bash")
        }
    }

    // MARK: Test 5b — isUnresolved transitions

    func testIsUnresolved() throws {
        let json: [String: Any] = ["stdout": "x", "stderr": "", "interrupted": false, "is_image": false]
        let toolUseJson: [String: Any] = ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "x"]]
        let origin = try ToolUse(json: toolUseJson)

        var obj = try ToolUseResultObject(json: json)
        XCTAssertTrue(obj.isUnresolved)
        try obj.resolve(from: origin)
        XCTAssertFalse(obj.isUnresolved)
    }

    // MARK: Test 5c — Resolve is idempotent

    func testResolveIdempotent() throws {
        let json: [String: Any] = ["stdout": "x", "stderr": "", "interrupted": false, "is_image": false]
        let toolUseJson: [String: Any] = ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "x"]]
        let origin = try ToolUse(json: toolUseJson)

        var obj = try ToolUseResultObject(json: json)
        do {
            try obj.resolve(from: origin)
        } catch {
            XCTFail("resolve(from:) threw: \(error)")
            return
        }
        XCTAssertFalse(obj.isUnresolved)

        // Calling resolve again with a different origin should be a no-op
        let origin2Json: [String: Any] = [
            "type": "tool_use", "id": "t2", "name": "Edit",
            "input": ["file_path": "/tmp/f.txt", "old_string": "a", "new_string": "b", "replace_all": false],
        ]
        let origin2 = try ToolUse(json: origin2Json)
        try obj.resolve(from: origin2)
        if case .Bash(_, _) = obj {
            // Still Bash, not changed to Edit
        } else {
            XCTFail("Expected .Bash after idempotent resolve, got \(obj)")
        }
    }

    // MARK: Test 5d — Unmatched origin case

    func testUnmatchedOriginCase() throws {
        let json: [String: Any] = ["stdout": "x", "stderr": "", "interrupted": false, "is_image": false]
        // Agent is a ToolUse case, use unknown to test the default branch
        let unknownToolJson: [String: Any] = ["type": "tool_use", "id": "t1", "name": "SomeFutureTool", "input": [:] as [String: Any]]
        let origin = try ToolUse(json: unknownToolJson)

        var obj = try ToolUseResultObject(json: json)
        try obj.resolve(from: origin)
        if case .unknown(let name, _, let o) = obj {
            XCTAssertEqual(name, "SomeFutureTool")
            XCTAssertNotNil(o)
        } else {
            XCTFail("Expected .unknown for unmatched origin case")
        }
    }

    // MARK: Test 6 — Resolver stateful index

    func testResolverStatefulIndex() throws {
        let resolver = Message2Resolver()

        // Feed an assistant message with tool_use (complete mock data)
        let assistantJson: [String: Any] = [
            "type": "assistant",
            "message": [
                "content": [
                    [
                        "type": "tool_use",
                        "id": "toolu_test123",
                        "name": "Bash",
                        "input": ["command": "echo hello"],
                    ] as [String: Any]
                ],
                "id": "msg_1",
                "model": "claude-sonnet-4-20250514",
                "role": "assistant",
                "stop_reason": "tool_use",
                "stop_sequence": "",
                "type": "message",
                "usage": [
                    "input_tokens": 10,
                    "output_tokens": 5,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "service_tier": "standard",
                    "cache_creation": [
                        "ephemeral_1h_input_tokens": 0,
                        "ephemeral_5m_input_tokens": 0,
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
            "session_id": "s1",
        ]
        let _ = try resolver.resolve(assistantJson)

        // Feed a user message with tool_result referencing that tool_use
        let userJson: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_test123",
                        "content": "output",
                    ] as [String: Any]
                ],
            ] as [String: Any],
            "tool_use_result": [
                "stdout": "hello",
                "stderr": "",
                "interrupted": false,
                "is_image": false,
            ] as [String: Any],
            "session_id": "s1",
        ]
        let userMsg = try resolver.resolve(userJson)

        if case .user(let user) = userMsg {
            if let result = user.toolUseResult, case .object(let obj) = result {
                if case .Bash(let bash, _) = obj {
                    XCTAssertEqual(bash.stdout, "hello")
                } else if case .unknown(let name, _, _) = obj {
                    XCTFail("Expected .Bash but got .unknown(\(name))")
                } else {
                    XCTFail("Expected .Bash, got \(obj)")
                }
            } else {
                XCTFail("Expected .object tool result")
            }
        } else {
            XCTFail("Expected .user message")
        }

        // After reset, index should be cleared
        resolver.reset()
        let userMsg2 = try resolver.resolve(userJson)
        if case .user(let user) = userMsg2 {
            if let result = user.toolUseResult, case .object(let obj) = result {
                if case .unknown(let name, _, _) = obj {
                    XCTAssertEqual(name, "unresolved", "After reset, should be unresolved")
                } else {
                    XCTFail("After reset, expected .unknown but got \(obj)")
                }
            }
        }
    }
}
