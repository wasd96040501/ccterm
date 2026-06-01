import AgentSDK
import XCTest

@testable import ccterm

/// Pins the `SSHLaunchBuilder` argv to the shape `RemoteSmoke.buildSSHArgv`
/// proved against a real remote (design `remote-execution.md` §3a/§3e). The
/// builder is pure, so these assert directly on the produced `LaunchPlan.wrapped`.
final class SSHLaunchBuilderTests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func unwrap(
        _ plan: LaunchPlan, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (
        String, [String]
    ) {
        guard case .wrapped(let exe, let argv) = plan else {
            XCTFail("expected .wrapped, got \(plan)", file: file, line: line)
            throw XCTSkip("not wrapped")
        }
        return (exe, argv)
    }

    private func host(
        host: String = "devbox", user: String? = nil, port: Int? = nil, identity: String? = nil
    ) -> RemoteHost {
        RemoteHost(alias: "dev", host: host, user: user, port: port, identityFile: identity)
    }

    private func inputs(
        host: RemoteHost, egress: SSHLaunchBuilder.Egress? = nil, credentialEnv: [String: String] = [:],
        claudeArgs: [String] = ["--output-format", "stream-json", "--session-id", "abc def"]
    ) -> SSHLaunchBuilder.Inputs {
        SSHLaunchBuilder.Inputs(
            host: host, sessionId: "abc def", remoteWorkdir: "/tmp/work dir",
            remoteClaudePath: "/home/u/.ccterm/bin/claude", claudeArguments: claudeArgs,
            credentialEnv: credentialEnv, egress: egress)
    }

    func testWrapsSSHExecutableWithNoPTYAndBatchMode() throws {
        let plan = SSHLaunchBuilder().makeLaunchPlan(inputs(host: host()))
        let (exe, argv) = try unwrap(plan)
        XCTAssertEqual(exe, "/usr/bin/ssh")
        XCTAssertEqual(argv.first, "-T", "no PTY → 8-bit-clean stream-json")
        XCTAssertTrue(argv.contains("BatchMode=yes"), "non-interactive launch never prompts")
        XCTAssertTrue(argv.contains("ServerAliveInterval=15"))
        // host token, then a single trailing remote-command string.
        XCTAssertEqual(argv[argv.count - 2], "devbox")
    }

    func testRemoteCommandExecsEnvClaudeWithQuotedArgs() throws {
        let (_, argv) = try unwrap(SSHLaunchBuilder().makeLaunchPlan(inputs(host: host())))
        let remoteCommand = try XCTUnwrap(argv.last)
        XCTAssertTrue(remoteCommand.contains("cd '/tmp/work dir'"), "workdir is single-quoted")
        XCTAssertTrue(remoteCommand.contains("exec env "), "exec so EOF/signals reach the real claude")
        XCTAssertTrue(remoteCommand.contains("'/home/u/.ccterm/bin/claude'"))
        // claude args embedded, byte-for-byte; the space-bearing value is quoted,
        // never split (the bug `LaunchPlan.wrapped` exists to fix).
        XCTAssertTrue(remoteCommand.contains("'--session-id' 'abc def'"))
    }

    func testEgressAddsReverseTunnelAndProxyEnv() throws {
        let egress = SSHLaunchBuilder.Egress(remoteForwardPort: 18991, macProxyHostPort: "127.0.0.1:1081")
        let (_, argv) = try unwrap(SSHLaunchBuilder().makeLaunchPlan(inputs(host: host(), egress: egress)))
        // per-session reverse tunnel: remote loopback port → the shared Mac proxy.
        guard let rIdx = argv.firstIndex(of: "-R") else { return XCTFail("missing -R") }
        XCTAssertEqual(argv[rIdx + 1], "127.0.0.1:18991:127.0.0.1:1081")
        let remoteCommand = try XCTUnwrap(argv.last)
        XCTAssertTrue(remoteCommand.contains("HTTPS_PROXY='http://127.0.0.1:18991'"))
        XCTAssertTrue(remoteCommand.contains("http_proxy='http://127.0.0.1:18991'"))
        XCTAssertFalse(remoteCommand.contains("NO_PROXY"), "remote must route all egress through the tunnel")
    }

    func testNoEgressOmitsReverseTunnelAndProxyEnv() throws {
        let (_, argv) = try unwrap(SSHLaunchBuilder().makeLaunchPlan(inputs(host: host(), egress: nil)))
        XCTAssertFalse(argv.contains("-R"))
        XCTAssertFalse(try XCTUnwrap(argv.last).contains("HTTPS_PROXY"))
    }

    func testCredentialEnvIsQuotedIntoRemoteCommand() throws {
        let creds = ["CLAUDE_CODE_OAUTH_TOKEN": "tok-with-'quote", "ANTHROPIC_API_KEY": "k"]
        let (_, argv) = try unwrap(SSHLaunchBuilder().makeLaunchPlan(inputs(host: host(), credentialEnv: creds)))
        let remoteCommand = try XCTUnwrap(argv.last)
        XCTAssertTrue(remoteCommand.contains("ANTHROPIC_API_KEY='k'"))
        // single quote inside the value is POSIX-escaped: ' → '\''
        XCTAssertTrue(remoteCommand.contains(#"CLAUDE_CODE_OAUTH_TOKEN='tok-with-'\''quote'"#))
    }

    func testConnectionOverridesEmittedOnlyWhenSet() throws {
        let bare = try unwrap(SSHLaunchBuilder().makeLaunchPlan(inputs(host: host()))).1
        XCTAssertFalse(bare.contains("-p"))
        XCTAssertFalse(bare.contains("-i"))
        XCTAssertFalse(bare.contains("-l"))

        let full = host(user: "alice", port: 2222, identity: "/keys/id_ed25519")
        let argv = try unwrap(SSHLaunchBuilder().makeLaunchPlan(inputs(host: full))).1
        XCTAssertEqual(argv[argv.firstIndex(of: "-p")! + 1], "2222")
        XCTAssertEqual(argv[argv.firstIndex(of: "-i")! + 1], "/keys/id_ed25519")
        XCTAssertEqual(argv[argv.firstIndex(of: "-l")! + 1], "alice")
    }
}
