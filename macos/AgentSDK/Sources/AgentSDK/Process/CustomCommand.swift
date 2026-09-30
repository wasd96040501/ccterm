import Foundation

/// Turns a user-configured custom launch command into a process invocation.
///
/// The Settings "Launch Command" field is meant to behave exactly like typing the
/// command at a terminal prompt. To honor that, a non-empty custom command is run
/// through the user's **interactive login shell** instead of being `exec`'d directly.
/// That makes all of the following work — none of which the old
/// `split(" ")` + `/usr/bin/which` + direct-exec path supported:
///
/// - **Aliases** — e.g. an `orange` alias in `~/.zshrc`. Aliases exist only inside an
///   interactive shell, so `/usr/bin/which orange` always failed with "binary not found".
/// - **Shell functions** — same reasoning as aliases.
/// - **Env-var prefixes** — `X=0 Z=1 claude` exports `X`/`Z` for the launched process.
/// - **Quoting / embedded spaces** — `claude --append-system-prompt "be terse"`.
/// - **Tilde & variable expansion** — `~/bin/claude`, `$HOME/bin/claude`.
///
/// SDK-built arguments are forwarded through `"$@"`, so values that contain spaces are
/// preserved verbatim (the old space-split mangled them).
///
/// Process lifecycle is unaffected: the SDK shuts the CLI down by closing stdin (EOF)
/// and interrupts via a JSON control request — both travel over the pipe the wrapping
/// shell hands straight to the child, so neither depends on signalling the shell.
enum CustomCommand {

    /// Builds `(executable, arguments)` that run `command` through the user's login shell
    /// with `sdkArgs` appended as positional parameters (`$1`, `$2`, …).
    ///
    /// `exports` are exported inside the script before the command: the shell runs `-li`,
    /// sourcing the rc files after the process environment is set, so an rc `export`
    /// would otherwise beat the caller's values. Precedence: rc exports < `exports` <
    /// the command's own prefix / alias assignments. Names that are not shell
    /// identifiers are skipped.
    ///
    /// - Precondition: `command` is non-empty (callers already guard this).
    static func shellInvocation(
        _ command: String,
        sdkArgs: [String],
        exports: [String: String]
    ) -> (executablePath: String, arguments: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? defaultShell
        // `export K='v'; … <command> "$@"`: the command runs after the exports (expanding
        // aliases / functions / env-prefixes / quoting), then the SDK args fill the
        // positional parameters.
        let exported = exports.keys.sorted().filter(isIdentifier).map { "export \($0)=\(quote(exports[$0]!)); " }
        let script = exported.joined() + command + " \"$@\""
        // -l (login) sources ~/.zprofile; -i (interactive) sources ~/.zshrc — aliases and
        // functions live in the latter. After `-c <script>`, the next argument becomes $0
        // and the remainder fill $1, $2, … which `"$@"` expands to.
        let arguments = ["-li", "-c", script, shellArgZero] + sdkArgs
        return (shell, arguments)
    }

    /// `value` as one single-quoted shell word.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isIdentifier(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// Fallback when `$SHELL` is unset — zsh is the macOS default login shell.
    static let defaultShell = "/bin/zsh"

    /// `$0` for the launch shell. Only ever surfaces in the shell's own diagnostics.
    static let shellArgZero = "ccterm-launch"
}
