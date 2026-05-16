#if DEBUG

import Foundation

/// Mock claude CLI subprocess entry point.
///
/// Process structure (orchestrated by `AppEntryPoint`):
/// ```
///   Parent (ccterm.app, launched by XCUI test) ──spawn──▶ Child (same ccterm
///                                                            binary, but
///                                                            CCTERM_RUN_AS_MOCK_CLI=1
///                                                            → MockCLIRunner.run())
/// ```
///
/// Communication:
/// - Parent → child: stdin, one JSON line per message (claude CLI stream-json
///   protocol).
/// - Child → parent: stdout, one JSON line per message (same).
/// - stderr is used for diagnostic output (unknown scenario / parse errors).
///
/// Execution model:
/// - Single-threaded, synchronous. `scenario.onStart` → `scenario.onIncoming(...)`
///   serialized in order.
/// - Scenarios may write to stdout immediately on receipt (within the same
///   call).
/// - stdin EOF / close → child exits 0.
enum MockCLIRunner {

    /// Entry point. **Never returns**: either `exit(0)` or `exit(1)`.
    static func run() -> Never {
        let env = ProcessInfo.processInfo.environment
        let scenarioName = env["CCTERM_MOCK_CLI_SCENARIO"] ?? ""

        guard let scenario = MockCLIRegistry.scenario(named: scenarioName) else {
            let names = MockCLIRegistry.scenarios.keys.sorted().joined(separator: ", ")
            writeStderr("[MockCLI] no scenario registered for name=\(scenarioName)\n")
            writeStderr("[MockCLI] available: \(names)\n")
            exit(1)
        }

        let stdout = FileHandle.standardOutput
        let sender = MockCLISender { data in
            stdout.write(data)
        }

        scenario.onStart(send: sender)

        readStdinLoop { json in
            let incoming = MockCLIIncoming.parse(json)
            scenario.onIncoming(incoming, send: sender)
        }

        // stdin EOF — host closed the pipe (typically SessionHandle2.stop's
        // close). Exit cleanly so onProcessExit(0) triggers the normal cleanup
        // path.
        exit(0)
    }

    // MARK: - I/O helpers

    private static func readStdinLoop(handle: (_ json: [String: Any]) -> Void) {
        let stdin = FileHandle.standardInput
        var buffer = Data()
        let newline = UInt8(ascii: "\n")

        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { return }  // EOF
            buffer.append(chunk)

            while let idx = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<idx]
                buffer.removeSubrange(buffer.startIndex...idx)
                guard !lineData.isEmpty else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    if let s = String(data: lineData, encoding: .utf8) {
                        writeStderr("[MockCLI] bad JSON line: \(s)\n")
                    }
                    continue
                }
                handle(json)
            }
        }
    }

    private static func writeStderr(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

#endif
