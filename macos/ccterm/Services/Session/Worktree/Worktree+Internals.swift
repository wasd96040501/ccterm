import AgentSDK
import Foundation
import Security

// MARK: - Names pool (Docker moby/pkg/namesgenerator; copied from claude.app slice lines 48/50)

fileprivate enum Names {
    static let adjectives: [String] = [
        "admiring", "adoring", "affectionate", "agitated", "amazing", "angry",
        "awesome", "beautiful", "blissful", "bold", "brave", "busy", "charming",
        "clever", "cool", "compassionate", "competent", "condescending", "confident",
        "cranky", "crazy", "dazzling", "determined", "distracted", "dreamy", "eager",
        "ecstatic", "elastic", "elated", "elegant", "eloquent", "epic", "exciting",
        "fervent", "festive", "flamboyant", "focused", "friendly", "frosty", "funny",
        "gallant", "gifted", "goofy", "gracious", "great", "happy", "hardcore",
        "heuristic", "hopeful", "hungry", "infallible", "inspiring", "interesting",
        "intelligent", "jolly", "jovial", "keen", "kind", "laughing", "loving",
        "lucid", "magical", "modest", "musing", "mystifying", "naughty", "nervous",
        "nice", "nifty", "nostalgic", "objective", "optimistic", "peaceful",
        "pedantic", "pensive", "practical", "priceless", "quirky", "quizzical",
        "recursing", "relaxed", "reverent", "romantic", "sad", "serene", "sharp",
        "silly", "sleepy", "stoic", "strange", "stupefied", "suspicious", "sweet",
        "tender", "thirsty", "trusting", "unruffled", "upbeat", "vibrant",
        "vigilant", "vigorous", "wizardly", "wonderful", "xenodochial", "youthful",
        "zealous", "zen",
    ]

    static let scientists: [String] = [
        "albattani", "allen", "almeida", "antonelli", "agnesi", "archimedes",
        "ardinghelli", "aryabhata", "austin", "babbage", "banach", "banzai",
        "bardeen", "bartik", "bassi", "beaver", "bell", "benz", "bhabha",
        "bhaskara", "black", "blackburn", "blackwell", "bohr", "booth", "borg",
        "bose", "bouman", "boyd", "brahmagupta", "brattain", "brown", "buck",
        "burnell", "cannon", "carson", "cartwright", "cerf", "chandrasekhar",
        "chaplygin", "chatelet", "chatterjee", "chebyshev", "cohen", "chaum",
        "clarke", "colden", "cori", "cray", "curran", "curie", "darwin", "davinci",
        "dewdney", "dhawan", "diffie", "dijkstra", "dirac", "driscoll", "dubinsky",
        "easley", "edison", "einstein", "elbakyan", "elgamal", "elion", "ellis",
        "engelbart", "euclid", "euler", "faraday", "feistel", "fermat", "fermi",
        "feynman", "franklin", "gagarin", "galileo", "gates", "gauss", "germain",
        "goldberg", "goldstine", "goldwasser", "golick", "goodall", "gould",
        "greider", "grothendieck", "haibt", "hamilton", "haslett", "hawking",
        "hellman", "heisenberg", "hermann", "herschel", "hertz", "heyrovsky",
        "hodgkin", "hofstadter", "hoover", "hopper", "hugle", "hypatia", "ishizaka",
        "jackson", "jang", "jemison", "jennings", "jepsen", "johnson", "joliot",
        "jones", "kalam", "kapitsa", "kare", "keller", "kepler", "khayyam",
        "khorana", "kilby", "kirch", "knuth", "kowalevski", "lalande", "lamarr",
        "lamport", "leakey", "leavitt", "lederberg", "lehmann", "lewin",
        "lichterman", "liskov", "lovelace", "lumiere", "mahavira", "margulis",
        "matsumoto", "maxwell", "mayer", "mccarthy", "mcclintock", "mclaren",
        "mclean", "mcnulty", "mendel", "mendeleev", "meitner", "meninsky", "merkle",
        "mestorf", "mirzakhani", "moore", "morse", "murdock", "moser", "napier",
        "nash", "neumann", "newton", "nightingale", "nobel", "noether", "northcutt",
        "noyce", "panini", "pare", "pascal", "pasteur", "payne", "perlman", "pike",
        "poincare", "poitras", "proskuriakova", "ptolemy", "raman", "ramanujan",
        "ride", "montalcini", "ritchie", "rhodes", "robinson", "roentgen",
        "rosalind", "rubin", "saha", "sammet", "sanderson", "satoshi", "shamir",
        "shannon", "shaw", "shirley", "shockley", "shtern", "sinoussi", "snyder",
        "solomon", "spence", "stonebraker", "sutherland", "swanson", "swartz",
        "swirles", "taussig", "tereshkova", "tesla", "tharp", "thompson",
        "torvalds", "tu", "turing", "varahamihira", "vaughan", "visvesvaraya",
        "volhard", "villani", "wescoff", "wilbur", "wiles", "williams",
        "williamson", "wilson", "wing", "wozniak", "wright", "wu", "yalow",
        "yonath", "zhukovsky",
    ]
}

// MARK: - Name generation

extension Worktree {

    /// Generate `<adj>-<sci>-<hex6>`. Callers decide their own retry
    /// strategy; this function does not deduplicate against used names
    /// (cross-process collisions in a 266M space are vanishingly rare;
    /// `create` falls back to retry on git command failure).
    static func generateName() -> String {
        let adj = Names.adjectives.randomElement()!
        let sci = Names.scientists.randomElement()!
        var bytes = [UInt8](repeating: 0, count: 3)
        _ = SecRandomCopyBytes(kSecRandomDefault, 3, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(adj)-\(sci)-\(hex)"
    }
}

// MARK: - Git query helpers

enum GitQuery {

    /// `git -C path rev-parse --git-dir`; absolute or relative path.
    static func gitDir(at path: String) -> String? {
        let r = Worktree.runGit(["rev-parse", "--git-dir"], cwd: path, timeout: 5)
        guard r.exitCode == 0, let out = r.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            return nil
        }
        return out
    }

    /// `git -C path rev-parse --git-common-dir`.
    static func gitCommonDir(at path: String) -> String? {
        let r = Worktree.runGit(["rev-parse", "--git-common-dir"], cwd: path, timeout: 5)
        guard r.exitCode == 0, let out = r.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            return nil
        }
        return out
    }

    /// `git -C path rev-parse --show-toplevel`.
    static func showToplevel(at path: String) -> String? {
        let r = Worktree.runGit(["rev-parse", "--show-toplevel"], cwd: path, timeout: 5)
        guard r.exitCode == 0, let out = r.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            return nil
        }
        return out
    }
}

// MARK: - Base repo normalization

extension Worktree {

    /// Mirrors claude.app `cQr` — if input is a worktree path, resolve to
    /// the main repo root; otherwise return as-is.
    ///
    /// Heuristic: `git-dir` containing `/.git/worktrees/` indicates a
    /// worktree; in that case `dirname(git-common-dir)` is the main repo root.
    static func resolveBaseRepo(_ path: String) -> String {
        guard let gitDir = GitQuery.gitDir(at: path),
            gitDir.contains("/.git/worktrees/"),
            let commonDir = GitQuery.gitCommonDir(at: path)
        else { return path }

        let absCommon =
            (commonDir as NSString).isAbsolutePath
            ? commonDir
            : ((path as NSString).appendingPathComponent(commonDir) as NSString).standardizingPath
        return (absCommon as NSString).deletingLastPathComponent
    }

    /// Whether git considers `path` a checked-out, **registered** worktree —
    /// independent of the exit code of the command that created it.
    ///
    /// `git worktree add` registers the worktree (writes
    /// `.git/worktrees/<name>` + the worktree's `.git` file) and checks the
    /// files out *before* running the `post-checkout` hook, then propagates
    /// the hook's exit code as its own. An LFS repo's `post-checkout` hook
    /// (`git lfs post-checkout`) failing therefore makes `worktree add` exit
    /// non-zero even though the worktree is fully present and usable. These
    /// hooks are advisory — git's own `git checkout` doesn't abort on them —
    /// so `create` uses this to tell that case apart from a real provision
    /// failure: a registered worktree's git-dir is `…/.git/worktrees/<name>`
    /// (the same criterion `resolveBaseRepo` keys off), whereas a half-failed
    /// add that never registered resolves up to the base repo's plain `.git`.
    static func isRegisteredWorktree(at path: String) -> Bool {
        guard let gitDir = GitQuery.gitDir(at: path) else { return false }
        return gitDir.contains("/.git/worktrees/")
    }
}

// MARK: - LFS

extension Worktree {

    /// Returns smudge/process/required-disable flags when `git-lfs` is
    /// missing from PATH; empty otherwise. Mirrors claude.app slice line
    /// 112: without LFS, prevents `git worktree add` from trying to smudge
    /// huge files and failing the whole operation.
    ///
    /// **Not cached** — tests need to flip state by changing PATH, and
    /// production call frequency is low enough that the cost is negligible.
    static func lfsFlagsIfUnavailable() -> [String] {
        if isLFSAvailable() { return [] }
        return [
            "-c", "filter.lfs.smudge=",
            "-c", "filter.lfs.process=",
            "-c", "filter.lfs.required=false",
        ]
    }

    private static func isLFSAvailable() -> Bool {
        let r = runCommand("/usr/bin/env", ["which", "git-lfs"], cwd: "/", timeout: 2)
        return r.exitCode == 0
    }
}

// MARK: - Subprocess environment

extension Worktree {

    /// The user's real login-shell environment, resolved once and cached.
    /// `nil` when the login shell can't be probed (callers fall back to the
    /// current process environment).
    ///
    /// Why this exists: a GUI app launched from Finder/Dock inherits a
    /// minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) that omits Homebrew
    /// (`/opt/homebrew/bin`). Running `git worktree add` under that PATH
    /// means git can't find `git-lfs`, so an LFS repo's `post-checkout`
    /// hook (`command -v git-lfs || exit 2`) fails the whole provision. The
    /// CLI subprocess already launches under the login environment
    /// (`AgentSDK.ShellEnvironment.loginEnvironment()`); resolving git
    /// provisioning the same way keeps the two consistent, so git-lfs,
    /// hooks, and credential helpers on the user's PATH are all found.
    ///
    /// Cached in a `static let` because `loginEnvironment()` spawns
    /// `zsh -li -c env` (hundreds of ms+) and one provision issues many git
    /// calls.
    static let cachedLoginEnvironment: [String: String]? = ShellEnvironment.loginEnvironment()

    /// Environment for a provisioning subprocess: the login environment (or
    /// `fallback` when unavailable) with `extra` layered on top. Mirrors the
    /// CLI's `loginEnvironment() ?? processEnvironment` precedence so the two
    /// launch in the same environment.
    static func resolvedEnvironment(extra: [String: String]) -> [String: String] {
        mergedEnvironment(
            base: cachedLoginEnvironment,
            fallback: ProcessInfo.processInfo.environment,
            extra: extra)
    }

    /// Pure merge used by `resolvedEnvironment`: `base` (or `fallback` when
    /// `base == nil`) with `extra` layered on top. Extracted so the
    /// precedence contract is unit-testable without spawning a shell.
    static func mergedEnvironment(
        base: [String: String]?,
        fallback: [String: String],
        extra: [String: String]
    ) -> [String: String] {
        var env = base ?? fallback
        for (key, value) in extra { env[key] = value }
        return env
    }
}

// MARK: - Fetch throttle

extension Worktree {

    fileprivate static let fetchAttemptStore = FetchAttemptStore()
    fileprivate static let fetchStaleThreshold: TimeInterval = 10 * 60
    fileprivate static let fetchTimeoutSeconds: TimeInterval = 15

    /// When FETCH_HEAD is stale and this process hasn't fetched recently:
    /// `git fetch --prune origin` (15s timeout). Silent on failure —
    /// on-disk refs still work. Mirrors claude.app `maybeRefreshOrigin`.
    static func refreshOriginIfStale(baseRepo: String) {
        if fetchAttemptStore.recentlyAttempted(baseRepo, threshold: fetchStaleThreshold) {
            return
        }
        if let age = fetchHeadAge(baseRepo: baseRepo), age < fetchStaleThreshold {
            return
        }
        fetchAttemptStore.mark(baseRepo)
        _ = runGit(
            ["fetch", "--prune", "origin"],
            cwd: baseRepo,
            timeout: fetchTimeoutSeconds,
            extraEnv: [
                "GCM_INTERACTIVE": "never",
                "GIT_ASKPASS": "",
                "SSH_ASKPASS": "",
                "GIT_SSH_COMMAND": "ssh -o BatchMode=yes",
            ]
        )
    }

    private static func fetchHeadAge(baseRepo: String) -> TimeInterval? {
        let gitDir = (baseRepo as NSString).appendingPathComponent(".git")
        let fetchHead = (gitDir as NSString).appendingPathComponent("FETCH_HEAD")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fetchHead),
            let mtime = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        return Date().timeIntervalSince(mtime)
    }
}

fileprivate final class FetchAttemptStore {
    private let queue = DispatchQueue(label: "Worktree.FetchAttemptStore")
    private var lastAttempts: [String: Date] = [:]

    func recentlyAttempted(_ repo: String, threshold: TimeInterval) -> Bool {
        queue.sync {
            guard let last = lastAttempts[repo] else { return false }
            return Date().timeIntervalSince(last) < threshold
        }
    }

    func mark(_ repo: String) {
        queue.sync { lastAttempts[repo] = Date() }
    }
}

// MARK: - Fast-forward local branch

extension Worktree {

    /// If local `<branch>` lags `origin/<branch>` and hasn't diverged,
    /// advance it via `update-ref` or `merge --ff-only`; silent on failure.
    /// Mirrors claude.app `maybeFastForwardLocalBranch`.
    static func maybeFastForwardLocalBranch(baseRepo: String, branch: String) {
        let localRef = "refs/heads/\(branch)"
        let originRef = "refs/remotes/origin/\(branch)"

        guard let local = revParse(baseRepo: baseRepo, ref: localRef),
            let origin = revParse(baseRepo: baseRepo, ref: originRef),
            local != origin
        else {
            return
        }
        guard isAncestor(baseRepo: baseRepo, ancestor: localRef, descendant: originRef) else {
            return
        }
        if let wt = worktreeCheckoutPath(baseRepo: baseRepo, localRef: localRef) {
            _ = runGit(["merge", "--ff-only", originRef], cwd: wt, timeout: 10)
        } else {
            _ = runGit(["update-ref", localRef, origin, local], cwd: baseRepo, timeout: 10)
        }
    }

    private static func worktreeCheckoutPath(baseRepo: String, localRef: String) -> String? {
        let r = runGit(
            ["for-each-ref", "--format=%(worktreepath)", localRef],
            cwd: baseRepo,
            timeout: 5
        )
        guard r.exitCode == 0,
            let out = r.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
            !out.isEmpty
        else {
            return nil
        }
        return out
    }
}

// MARK: - Resolve start point

extension Worktree {

    /// Decide the `worktree add` start point.
    /// - sourceBranch == nil → base's current branch; detached → nil
    /// - Prefer `origin/<src>` (origin exists && (local missing || local is-ancestor-of origin))
    /// - Otherwise local refs/heads/<src>
    /// - Otherwise raw <src>
    /// - None → nil
    static func resolveStartPoint(baseRepo: String, sourceBranch: String?) -> String? {
        guard let src = sourceBranch else {
            return GitUtils.currentBranch(at: baseRepo)
        }
        let originRef = "refs/remotes/origin/\(src)"
        let localRef = "refs/heads/\(src)"
        let originExists = revParse(baseRepo: baseRepo, ref: originRef) != nil
        let localExists = revParse(baseRepo: baseRepo, ref: localRef) != nil

        if originExists {
            let preferOrigin =
                !localExists
                || isAncestor(baseRepo: baseRepo, ancestor: localRef, descendant: originRef)
            if preferOrigin { return originRef }
        }
        if localExists { return localRef }
        if revParse(baseRepo: baseRepo, ref: src) != nil { return src }
        return nil
    }
}

// MARK: - Worktree path

extension Worktree {

    /// `<baseRepo>/.claude/worktrees/<name>` (single level, no projectName).
    static func worktreeDir(baseRepo: String, name: String) -> String {
        let base = (baseRepo as NSString).appendingPathComponent(".claude/worktrees")
        return (base as NSString).appendingPathComponent(name)
    }
}

// MARK: - Config / hooks / file copy

extension Worktree {

    /// Enable `extensions.worktreeConfig` + `--worktree core.longpaths=true`.
    static func enableWorktreeConfigExtensions(at worktreePath: String) {
        _ = runGit(["config", "extensions.worktreeConfig", "true"], cwd: worktreePath, timeout: 5)
        _ = runGit(["config", "--worktree", "core.longpaths", "true"], cwd: worktreePath, timeout: 5)
    }

    /// Three-tier fallback: `core.hooksPath` → `.husky` →
    /// `git-common-dir/hooks`. Writes to the worktree config in
    /// `--worktree` scope. Mirrors claude.app `configureHooksPath`.
    static func inheritHooksPath(source: String, worktree: String) {
        _ = runGit(["config", "extensions.worktreeConfig", "true"], cwd: worktree, timeout: 5)

        // 1. base's explicit core.hooksPath
        let baseHooks = runGit(
            ["config", "--type=path", "--get", "core.hooksPath"],
            cwd: source,
            timeout: 5
        )
        if baseHooks.exitCode == 0,
            let out = baseHooks.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
            !out.isEmpty
        {
            let absolute =
                (out as NSString).isAbsolutePath
                ? out
                : (source as NSString).appendingPathComponent(out)
            let set = runGit(
                ["config", "--worktree", "core.hooksPath", absolute],
                cwd: worktree,
                timeout: 5
            )
            if set.exitCode == 0 { return }
        }

        // 2. `<source>/.husky`
        let husky = (source as NSString).appendingPathComponent(".husky")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: husky, isDirectory: &isDir), isDir.boolValue {
            let r = runGit(
                ["config", "--worktree", "core.hooksPath", husky],
                cwd: worktree,
                timeout: 5
            )
            if r.exitCode == 0 { return }
        }

        // 3. git-common-dir/hooks containing non-.sample files
        let common = runGit(["rev-parse", "--git-common-dir"], cwd: source, timeout: 5)
        if common.exitCode == 0,
            let out = common.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
            !out.isEmpty
        {
            let hooksDir =
                (out as NSString).isAbsolutePath
                ? (out as NSString).appendingPathComponent("hooks")
                : ((source as NSString).appendingPathComponent(out) as NSString).appendingPathComponent("hooks")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: hooksDir),
                files.contains(where: { !$0.hasSuffix(".sample") })
            {
                _ = runGit(
                    ["config", "--worktree", "core.hooksPath", hooksDir],
                    cwd: worktree,
                    timeout: 5
                )
            }
        }
    }

    /// Read non-comment lines from `<source>/.worktreeinclude` as
    /// pathspecs; use `git ls-files --others --ignored --exclude-standard`
    /// to enumerate matching gitignored files, then copy by relative path
    /// into the worktree. Mirrors claude.app `B0r` (slice lines 1-24).
    /// Per-file failures are logged only.
    static func copyWorktreeIncludeFiles(source: String, worktree: String) {
        let includeFile = (source as NSString).appendingPathComponent(".worktreeinclude")
        guard let content = try? String(contentsOfFile: includeFile, encoding: .utf8) else { return }

        let patterns = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !patterns.isEmpty else { return }

        copyGitignoredMatches(source: source, worktree: worktree, pathspecs: patterns, label: ".worktreeinclude")
    }

    /// Copy every gitignored file under `<source>/.claude` into the
    /// worktree. Mirrors claude.app `Q0r` (slice lines 25-41). Overlaps
    /// with `copySettingsLocal` (`.claude/settings.local.json`); idempotent.
    ///
    /// `.claude/worktrees/**` is excluded — that's where ccterm provisions
    /// its own worktrees. They're full source-tree copies (with build
    /// products) that are by definition untracked-because-ignored, so the
    /// raw `ls-files --others --ignored` enumeration would pick them up
    /// and recursively copy every old worktree into the new one. On a repo
    /// with N existing worktrees that turns a fast operation into a
    /// quadratic copy + APFS-filename-length failures (the doubled path
    /// `<new>/.claude/worktrees/<old>/.../<deeply-nested>.swift` blows past
    /// the 255-byte limit and FileManager throws).
    ///
    /// We filter in Swift rather than via git pathspec because git
    /// `ls-files --others --ignored` emits whole-ignored-directory entries
    /// as `<dir>/` (no recursion into them); pathspec `:(exclude)` matches
    /// individual entries, not the directory entry that wraps a gitignored
    /// subtree, so it doesn't help here.
    static func copyGitignoredClaudeFiles(source: String, worktree: String) {
        let claudeDir = (source as NSString).appendingPathComponent(".claude")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: claudeDir, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        copyGitignoredMatches(
            source: source,
            worktree: worktree,
            pathspecs: [".claude"],
            label: ".claude",
            relativeFilter: { rel in
                // Drop our own worktree-management directory; see the
                // doc-comment above for why.
                !(rel == ".claude/worktrees"
                    || rel == ".claude/worktrees/"
                    || rel.hasPrefix(".claude/worktrees/"))
            }
        )
    }

    /// Standalone `.claude/settings.local.json` copy — for the `restore`
    /// path (where we don't want to rerun the full gitignored enumeration).
    /// The `create` path is covered by `copyGitignoredClaudeFiles`.
    static func copySettingsLocal(source: String, worktree: String) {
        let src = (source as NSString).appendingPathComponent(".claude/settings.local.json")
        guard FileManager.default.fileExists(atPath: src) else { return }
        let destDir = (worktree as NSString).appendingPathComponent(".claude")
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let dest = (destDir as NSString).appendingPathComponent("settings.local.json")
        try? FileManager.default.copyItem(atPath: src, toPath: dest)
    }

    private static func copyGitignoredMatches(
        source: String,
        worktree: String,
        pathspecs: [String],
        label: String,
        relativeFilter: ((String) -> Bool)? = nil
    ) {
        let args = ["ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--"] + pathspecs
        let r = runGit(args, cwd: source, timeout: 10)
        guard r.exitCode == 0, let out = r.stdout, !out.isEmpty else { return }

        // `-z` → NUL-separated (safe for filenames with newlines or
        // special characters)
        var relatives = out.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        if let filter = relativeFilter {
            let before = relatives.count
            relatives = relatives.filter(filter)
            let dropped = before - relatives.count
            if dropped > 0 {
                appLog(
                    .info, "Worktree",
                    "copy \(label) filter dropped \(dropped) entr\(dropped == 1 ? "y" : "ies")")
            }
        }
        guard !relatives.isEmpty else { return }

        var copied = 0
        for rel in relatives {
            let srcPath = (source as NSString).appendingPathComponent(rel)
            let dstPath = (worktree as NSString).appendingPathComponent(rel)
            let dstDir = (dstPath as NSString).deletingLastPathComponent
            do {
                try FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dstPath) {
                    try FileManager.default.removeItem(atPath: dstPath)
                }
                try FileManager.default.copyItem(atPath: srcPath, toPath: dstPath)
                copied += 1
            } catch {
                appLog(.warning, "Worktree", "copy \(label) failed: \(rel) err=\(error.localizedDescription)")
            }
        }
        if copied > 0 {
            appLog(.info, "Worktree", "copied \(copied) gitignored \(label) file(s) to worktree")
        }
    }
}

// MARK: - Git process wrapper

extension Worktree {

    struct GitResult {
        let exitCode: Int32
        let stdout: String?
        let stderr: String?
    }

    @discardableResult
    static func runGit(
        _ args: [String],
        cwd: String,
        timeout: TimeInterval,
        extraEnv: [String: String] = [:]
    ) -> GitResult {
        runCommand("/usr/bin/git", ["-C", cwd] + args, cwd: cwd, timeout: timeout, extraEnv: extraEnv)
    }

    @discardableResult
    static func runCommand(
        _ executable: String,
        _ args: [String],
        cwd: String,
        timeout: TimeInterval,
        extraEnv: [String: String] = [:]
    ) -> GitResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if FileManager.default.fileExists(atPath: cwd) {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        proc.environment = Self.resolvedEnvironment(extra: extraEnv)
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return GitResult(exitCode: -1, stdout: nil, stderr: error.localizedDescription)
        }

        let timeoutItem = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        timeoutItem.cancel()

        return GitResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8),
            stderr: String(data: stderrData, encoding: .utf8)
        )
    }

    static func revParse(baseRepo: String, ref: String) -> String? {
        let r = runGit(["rev-parse", "--verify", "--quiet", ref], cwd: baseRepo, timeout: 5)
        guard r.exitCode == 0, let sha = r.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty else {
            return nil
        }
        return sha
    }

    static func isAncestor(baseRepo: String, ancestor: String, descendant: String) -> Bool {
        let r = runGit(
            ["merge-base", "--is-ancestor", ancestor, descendant],
            cwd: baseRepo,
            timeout: 5
        )
        return r.exitCode == 0
    }
}
