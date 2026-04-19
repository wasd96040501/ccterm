import Foundation
import Security

// MARK: - Names pool（Docker moby/pkg/namesgenerator，照搬 claude.app slice 行 48/50）

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

    /// 生成 `<adj>-<sci>-<hex6>`。调用方可自行决定冲突重试策略；本函数不做
    /// "已用过去重"（2.66 亿空间下跨进程冲突概率极低，create 内部用 git 命令失败兜底）。
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

    /// `git -C path rev-parse --git-dir`，输出绝对或相对路径。
    static func gitDir(at path: String) -> String? {
        let r = Worktree.runGit(["rev-parse", "--git-dir"], cwd: path, timeout: 5)
        guard r.exitCode == 0, let out = r.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            return nil
        }
        return out
    }

    /// `git -C path rev-parse --git-common-dir`。
    static func gitCommonDir(at path: String) -> String? {
        let r = Worktree.runGit(["rev-parse", "--git-common-dir"], cwd: path, timeout: 5)
        guard r.exitCode == 0, let out = r.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            return nil
        }
        return out
    }

    /// `git -C path rev-parse --show-toplevel`。
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

    /// 对齐 claude.app `cQr`——入参若是 worktree 路径，解析到 main repo root；
    /// 否则返原路径。
    ///
    /// 判据：`git-dir` 包含 `/.git/worktrees/` 即是 worktree；此时 `dirname(git-common-dir)`
    /// 就是 main repo root。
    static func resolveBaseRepo(_ path: String) -> String {
        guard let gitDir = GitQuery.gitDir(at: path),
              gitDir.contains("/.git/worktrees/"),
              let commonDir = GitQuery.gitCommonDir(at: path)
        else { return path }

        let absCommon = (commonDir as NSString).isAbsolutePath
            ? commonDir
            : ((path as NSString).appendingPathComponent(commonDir) as NSString).standardizingPath
        return (absCommon as NSString).deletingLastPathComponent
    }
}

// MARK: - LFS

extension Worktree {

    /// 若系统 PATH 无 `git-lfs`，返回 smudge/process/required 禁用 flags；有则空数组。
    /// 对齐 claude.app slice 行 112：无 LFS 时避免 `git worktree add` 尝试 smudge
    /// 大文件导致整体失败。
    ///
    /// 结果**不缓存**——测试要能通过修改 PATH 切换状态。生产调用次数少，可忽略成本。
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

// MARK: - Fetch throttle

extension Worktree {

    fileprivate static let fetchAttemptStore = FetchAttemptStore()
    fileprivate static let fetchStaleThreshold: TimeInterval = 10 * 60
    fileprivate static let fetchTimeoutSeconds: TimeInterval = 15

    /// FETCH_HEAD 陈旧且本进程未近期 fetch 过 → `git fetch --prune origin`（15s 超时）。
    /// 失败静默——on-disk refs 仍可用。对齐 claude.app `maybeRefreshOrigin`。
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
              let mtime = attrs[.modificationDate] as? Date else {
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

    /// 若 local `<branch>` 落后 `origin/<branch>` 且未分叉，用 `update-ref` 或
    /// `merge --ff-only` 推进；失败静默。对齐 claude.app `maybeFastForwardLocalBranch`。
    static func maybeFastForwardLocalBranch(baseRepo: String, branch: String) {
        let localRef = "refs/heads/\(branch)"
        let originRef = "refs/remotes/origin/\(branch)"

        guard let local = revParse(baseRepo: baseRepo, ref: localRef),
              let origin = revParse(baseRepo: baseRepo, ref: originRef),
              local != origin else {
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
              !out.isEmpty else {
            return nil
        }
        return out
    }
}

// MARK: - Resolve start point

extension Worktree {

    /// 决定 `worktree add` 的 start point。
    /// - sourceBranch == nil → base 当前 branch；detached → nil
    /// - 优先 `origin/<src>`（origin 存在 && （local 不存在 || local is-ancestor-of origin））
    /// - 否则 local refs/heads/<src>
    /// - 否则 raw <src>
    /// - 都不存在 → nil
    static func resolveStartPoint(baseRepo: String, sourceBranch: String?) -> String? {
        guard let src = sourceBranch else {
            return GitUtils.currentBranch(at: baseRepo)
        }
        let originRef = "refs/remotes/origin/\(src)"
        let localRef = "refs/heads/\(src)"
        let originExists = revParse(baseRepo: baseRepo, ref: originRef) != nil
        let localExists = revParse(baseRepo: baseRepo, ref: localRef) != nil

        if originExists {
            let preferOrigin = !localExists
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

    /// `<baseRepo>/.claude/worktrees/<name>`（单层，无 projectName）。
    static func worktreeDir(baseRepo: String, name: String) -> String {
        let base = (baseRepo as NSString).appendingPathComponent(".claude/worktrees")
        return (base as NSString).appendingPathComponent(name)
    }
}

// MARK: - Config / hooks / file copy

extension Worktree {

    /// 开启 `extensions.worktreeConfig` + `--worktree core.longpaths=true`。
    static func enableWorktreeConfigExtensions(at worktreePath: String) {
        _ = runGit(["config", "extensions.worktreeConfig", "true"], cwd: worktreePath, timeout: 5)
        _ = runGit(["config", "--worktree", "core.longpaths", "true"], cwd: worktreePath, timeout: 5)
    }

    /// `core.hooksPath` → `.husky` → `git-common-dir/hooks` 三级 fallback，
    /// 以 `--worktree` scope 写入 worktree config。对齐 claude.app `configureHooksPath`。
    static func inheritHooksPath(source: String, worktree: String) {
        _ = runGit(["config", "extensions.worktreeConfig", "true"], cwd: worktree, timeout: 5)

        // 1. base 显式 core.hooksPath
        let baseHooks = runGit(
            ["config", "--type=path", "--get", "core.hooksPath"],
            cwd: source,
            timeout: 5
        )
        if baseHooks.exitCode == 0,
           let out = baseHooks.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
           !out.isEmpty {
            let absolute = (out as NSString).isAbsolutePath
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

        // 3. git-common-dir/hooks 含非 .sample 文件
        let common = runGit(["rev-parse", "--git-common-dir"], cwd: source, timeout: 5)
        if common.exitCode == 0,
           let out = common.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
           !out.isEmpty {
            let hooksDir = (out as NSString).isAbsolutePath
                ? (out as NSString).appendingPathComponent("hooks")
                : ((source as NSString).appendingPathComponent(out) as NSString).appendingPathComponent("hooks")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: hooksDir),
               files.contains(where: { !$0.hasSuffix(".sample") }) {
                _ = runGit(
                    ["config", "--worktree", "core.hooksPath", hooksDir],
                    cwd: worktree,
                    timeout: 5
                )
            }
        }
    }

    /// 读 `<source>/.worktreeinclude` 非注释行作为 pathspec，`git ls-files --others
    /// --ignored --exclude-standard` 枚举匹配的 gitignored 文件，按相对路径拷贝到 worktree。
    /// 对齐 claude.app `B0r`（slice 行 1-24）。失败单条仅日志。
    static func copyWorktreeIncludeFiles(source: String, worktree: String) {
        let includeFile = (source as NSString).appendingPathComponent(".worktreeinclude")
        guard let content = try? String(contentsOfFile: includeFile, encoding: .utf8) else { return }

        let patterns = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !patterns.isEmpty else { return }

        copyGitignoredMatches(source: source, worktree: worktree, pathspecs: patterns, label: ".worktreeinclude")
    }

    /// 把 `<source>/.claude` 下所有 gitignored 文件拷到 worktree。对齐 claude.app `Q0r`
    /// （slice 行 25-41）。与 `copySettingsLocal` 有部分交集（`.claude/settings.local.json`），
    /// 幂等。
    static func copyGitignoredClaudeFiles(source: String, worktree: String) {
        let claudeDir = (source as NSString).appendingPathComponent(".claude")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: claudeDir, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        copyGitignoredMatches(source: source, worktree: worktree, pathspecs: [".claude"], label: ".claude")
    }

    /// 单独的 `.claude/settings.local.json` 拷贝——用于 `restore` 场景（不想重新跑完整
    /// gitignored 枚举）。`create` 路径由 `copyGitignoredClaudeFiles` 覆盖。
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
        label: String
    ) {
        let args = ["ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--"] + pathspecs
        let r = runGit(args, cwd: source, timeout: 10)
        guard r.exitCode == 0, let out = r.stdout, !out.isEmpty else { return }

        // `-z` → NUL 分隔（含多行 / 特殊字符文件名安全）
        let relatives = out.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
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
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        proc.environment = env
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
