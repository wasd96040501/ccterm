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
public enum CustomCommand {

    /// Builds `(executable, arguments)` that run `command` through the user's login shell
    /// with `sdkArgs` appended as positional parameters (`$1`, `$2`, …).
    ///
    /// - Precondition: `command` is non-empty (callers already guard this).
    public static func shellInvocation(
        _ command: String,
        sdkArgs: [String]
    ) -> (executablePath: String, arguments: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? defaultShell
        // `<command> "$@"`: the command runs first (expanding aliases / functions /
        // env-prefixes / quoting), then the SDK args fill the positional parameters.
        let script = command + " \"$@\""
        // -l (login) sources ~/.zprofile; -i (interactive) sources ~/.zshrc — aliases and
        // functions live in the latter. After `-c <script>`, the next argument becomes $0
        // and the remainder fill $1, $2, … which `"$@"` expands to.
        let arguments = ["-li", "-c", script, shellArgZero] + sdkArgs
        return (shell, arguments)
    }

    /// Fallback when `$SHELL` is unset — zsh is the macOS default login shell.
    static let defaultShell = "/bin/zsh"

    /// `$0` for the launch shell. Only ever surfaces in the shell's own diagnostics.
    static let shellArgZero = "ccterm-launch"
}
