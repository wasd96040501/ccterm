import AgentSDK
import XCTest

/// Verifies that a user-configured "Launch Command" is turned into an
/// **interactive login-shell** invocation rather than being space-split and
/// `which`-resolved. The old path failed for the most natural inputs — a
/// `~/.zshrc` alias (`/usr/bin/which orange` can't see aliases), an env-var
/// prefix (`X=0 claude` tried to `which X=0`), and any argument containing a
/// space. Running through the shell fixes all of them at once.
///
/// These assert the pure invocation shape (no process is spawned), which is
/// exactly the behavior the bug turned on: the command must reach the shell
/// verbatim and the SDK args must ride in via `"$@"`.
final class CustomCommandTests: XCTestCase {

    /// `shellInvocation` resolves the executable from `$SHELL`.
    private var expectedShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    // MARK: - Shell wrapping shape

    func testExecutableIsLoginShell() {
        let (exe, _) = CustomCommand.shellInvocation("orange", sdkArgs: [])
        XCTAssertEqual(exe, expectedShell)
    }

    func testUsesLoginInteractiveFlags() {
        let (_, args) = CustomCommand.shellInvocation("orange", sdkArgs: [])
        // `-li` = login + interactive so ~/.zprofile and ~/.zshrc are sourced;
        // `-c` introduces the script. Order matters: -li, then -c, then script.
        XCTAssertEqual(Array(args.prefix(2)), ["-li", "-c"])
        let cIndex = args.firstIndex(of: "-c")
        XCTAssertNotNil(cIndex)
    }

    func testScriptForwardsSdkArgsViaPositionalParams() {
        let (_, args) = CustomCommand.shellInvocation("orange", sdkArgs: [])
        // The script after `-c` must end in `"$@"` so SDK args land as positional params.
        guard let cIndex = args.firstIndex(of: "-c"), cIndex + 1 < args.count else {
            return XCTFail("missing -c script")
        }
        XCTAssertEqual(args[cIndex + 1], "orange \"$@\"")
    }

    // MARK: - Alias preserved verbatim (the reported bug)

    func testAliasNamePassedThroughUntouched() {
        // The crux: `orange` reaches the shell as-is — NOT pre-resolved via
        // `/usr/bin/which`, which never sees shell aliases.
        let (_, args) = CustomCommand.shellInvocation("orange", sdkArgs: [])
        XCTAssertTrue(args.contains("orange \"$@\""))
        XCTAssertFalse(args.contains { $0.contains("/usr/bin/which") })
    }

    // MARK: - Env-var prefix (the second reported gap)

    func testEnvVarPrefixPreservedInScript() {
        // `X=0 Z=1 claude --` previously made the resolver try to `which X=0`.
        // Now the whole string reaches the shell, which applies X/Z to the launch.
        let (_, args) = CustomCommand.shellInvocation("X=0 Z=1 claude --", sdkArgs: ["-p", "json"])
        guard let cIndex = args.firstIndex(of: "-c") else { return XCTFail("missing -c") }
        XCTAssertEqual(args[cIndex + 1], "X=0 Z=1 claude -- \"$@\"")
    }

    // MARK: - SDK arg forwarding

    func testSdkArgsAppendedAfterArgZero() {
        let sdk = ["-p", "--output-format", "stream-json", "--model", "opus"]
        let (_, args) = CustomCommand.shellInvocation("claude", sdkArgs: sdk)
        // Layout: ["-li", "-c", script, $0, sdk...]. $0 is a fixed launch label;
        // every SDK arg follows it, in order, each as its own element.
        XCTAssertEqual(Array(args.suffix(sdk.count)), sdk)
        XCTAssertEqual(args.count, 4 + sdk.count)
    }

    func testArgZeroSeparatesScriptFromForwardedArgs() {
        let (_, args) = CustomCommand.shellInvocation("claude", sdkArgs: ["-p"])
        // Element 3 is $0 (the shell's own name slot); the SDK args start at $1.
        XCTAssertEqual(args[3], "ccterm-launch")
        XCTAssertEqual(args[4], "-p")
    }

    func testSdkArgWithSpacesStaysOneElement() {
        // The old space-split shattered this into separate argv entries; as a
        // forwarded positional param it survives intact.
        let sdk = ["--append-system-prompt", "be terse and kind"]
        let (_, args) = CustomCommand.shellInvocation("claude", sdkArgs: sdk)
        XCTAssertEqual(args.last, "be terse and kind")
    }

    func testEmptySdkArgsProducesBareShellInvocation() {
        let (_, args) = CustomCommand.shellInvocation("claude", sdkArgs: [])
        XCTAssertEqual(args, ["-li", "-c", "claude \"$@\"", "ccterm-launch"])
    }

    // MARK: - Quoting / paths with spaces survive (handled by the shell, not us)

    func testCommandStringIsNotPreSplit() {
        // A quoted path with a space must reach the shell as a single script so the
        // shell's own parser handles the quoting — we must not tokenize it ourselves.
        let cmd = "\"/Users/me/My Tools/claude\" --foo"
        let (_, args) = CustomCommand.shellInvocation(cmd, sdkArgs: [])
        guard let cIndex = args.firstIndex(of: "-c") else { return XCTFail("missing -c") }
        XCTAssertEqual(args[cIndex + 1], cmd + " \"$@\"")
    }
}
