import Foundation
import SwiftParser
import SwiftSyntax

// Usage: ArchMap <macos-dir> <out-dir> [scope] [detail]
//
// detail: `members` also writes `<unit>.members.md` per unit — inside each
//   type, its state and who writes it, and how its members call one another
//   (`MemberMap`).
//
// scope: comma/space-separated tokens, each one of
//   core (default) — the app + every package library (no demos, smokes, tests)
//   app | kit | sdk — ccterm / TranscriptKit's libraries / AgentSDK
//   <path>         — a directory or file (demo and smoke targets too)
//   <unit>         — as the map names it (`AgentSDK/Session`), or its last
//                    directories alone (`sidebar`)
// Every target is parsed, so names resolve and demo / smoke use of package API
// counts as use; only the scope is written.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: ArchMap <macos-dir> <out-dir> [scope]\n".data(using: .utf8)!)
    exit(2)
}
let root = URL(fileURLWithPath: args[1]).standardizedFileURL
let outDir = URL(fileURLWithPath: args[2]).standardizedFileURL
let scopeArg = args.count > 3 && !args[3].isEmpty ? args[3] : "core"
let detail = args.count > 4 ? args[4] : ""
guard ["", "members"].contains(detail) else {
    FileHandle.standardError.write("error: DETAIL '\(detail)' is unknown. Use members.\n".data(using: .utf8)!)
    exit(2)
}

// MARK: Modules

struct Module {
    let name: String
    let dir: String  // relative to macos/
    let isLibrary: Bool
}

let fm = FileManager.default

@MainActor func swiftFiles(in dir: String) -> [String] {
    guard let walker = fm.enumerator(atPath: root.appendingPathComponent(dir).path) else { return [] }
    return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { dir + "/" + $0 }.sorted()
}

@MainActor func read(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

var modules = [Module(name: "ccterm", dir: "ccterm", isLibrary: true)]
for package in (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? [] {
    let sources = package + "/Sources"
    guard let targets = try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(sources).path) else { continue }
    for target in targets.sorted() where !target.hasPrefix(".") {
        let dir = sources + "/" + target
        let files = swiftFiles(in: dir)
        let executable = files.contains { $0.hasSuffix("/main.swift") || read($0).contains("@main") }
        modules.append(Module(name: target, dir: dir, isLibrary: !executable))
    }
}

let namedScopes: [String: [String]] = [
    "core": modules.filter(\.isLibrary).map(\.dir),
    "app": ["ccterm"],
    "kit": modules.filter { $0.isLibrary && $0.dir.hasPrefix("TranscriptKit/") }.map(\.dir),
    "sdk": modules.filter { $0.isLibrary && $0.dir.hasPrefix("AgentSDK/") }.map(\.dir),
]

// MARK: Parse

var sources: [SourceFile] = []
for module in modules {
    for path in swiftFiles(in: module.dir) {
        let text = read(path)
        let tree = Parser.parse(source: text)
        let relative = (path as NSString).deletingLastPathComponent.dropFirst(module.dir.count)
        let unit = module.name + relative
        let imports = tree.statements.compactMap { $0.item.as(ImportDeclSyntax.self)?.path.trimmedDescription }
        sources.append(
            SourceFile(
                path: path, module: module.name, unit: unit,
                lines: text.split(separator: "\n", omittingEmptySubsequences: false).count,
                imports: imports, tree: tree))
    }
}

// MARK: Scope

/// The files one scope token selects: a named scope, a path (from the repo
/// root, from macos/, or absolute), a unit as the map prints it
/// (`AgentSDK/Session`), or — failing those — a unit's trailing directory
/// names, case-insensitively (`sidebar`, `services/library`).
@MainActor func select(_ token: String) -> [SourceFile] {
    let under = { (path: String, prefix: String) in path == prefix || path.hasPrefix(prefix + "/") }
    if let dirs = namedScopes[token] { return sources.filter { file in dirs.contains { under(file.path, $0) } } }
    var path = token
    for prefix in [root.path + "/", "macos/", "./"] where path.hasPrefix(prefix) {
        path = String(path.dropFirst(prefix.count))
    }
    while path.hasSuffix("/") { path.removeLast() }
    let exact = sources.filter { under($0.path, path) || under($0.unit, path) }
    if !exact.isEmpty { return exact }
    let tail = "/" + path.lowercased()
    return sources.filter { file in
        let unit = file.unit.lowercased()
        return unit.hasSuffix(tail) || unit == path.lowercased() || unit.contains(tail + "/")
    }
}

var scoped: [SourceFile] = []
for token in scopeArg.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) {
    let hits = select(token)
    guard !hits.isEmpty else {
        let units = Set(sources.map(\.unit)).sorted().map { "  " + $0 }.joined(separator: "\n")
        FileHandle.standardError.write(
            "error: SCOPE '\(token)' matches nothing. Use core, app, kit, sdk, a path, or a unit:\n\(units)\n"
                .data(using: .utf8)!)
        exit(1)
    }
    scoped += hits
}
let scopedPaths = Set(scoped.map(\.path))

let index = Index(files: sources)

/// Member names the test targets reach (`x.name`). Tests aren't mapped, but a
/// member they exercise is surface, not a type's own detail.
final class MemberNames: SyntaxVisitor {
    var names: Set<String> = []
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.declName.baseName.text)
        return .visitChildren
    }
}
let testNames = MemberNames(viewMode: .sourceAccurate)
var testDirs = ["cctermTests"]
for package in (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
where fm.fileExists(atPath: root.appendingPathComponent(package + "/Tests").path) {
    testDirs.append(package + "/Tests")
}
for dir in testDirs {
    for path in swiftFiles(in: dir) { testNames.walk(Parser.parse(source: read(path))) }
}
index.testedMembers = testNames.names
let units = Array(Set(scoped.map(\.unit))).sorted()

// MARK: Write

@MainActor func git(_ arguments: String...) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

let dirty = git("status", "--porcelain", "--", ".").isEmpty ? "" : " + uncommitted changes"
let scopedLines = sources.filter { scopedPaths.contains($0.path) }.reduce(0) { $0 + $1.lines }
let header = """
    # Architecture map — scope `\(scopeArg)`

    Generated from `\(git("rev-parse", "--short", "HEAD"))`\(dirty) by `make arch`. \
    \(units.count) units · \(scopedLines) lines. Regenerated in full on every run; never edit by hand.
    """

let renderer = Renderer(index: index, files: sources, units: units, header: header)
try? fm.removeItem(at: outDir)
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
var indexText = renderer.renderIndex()
if detail == "members" {
    let map = MemberMap(index: index, files: sources)
    indexText += "\n## Member maps\n\n"
    for unit in units {
        let name = Renderer.fileName(ofUnit: unit).replacingOccurrences(of: ".md", with: ".members.md")
        try map.render(unit: unit, header: "# \(unit) — members").write(
            to: outDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        indexText += "- [\(unit)](\(name))\n"
    }
}
// The app's placement and component boundaries, whatever the scope: a scope
// picks what the map describes, while a break is a fact about the app's tree.
let rules = Rules(
    index: index, modules: ["ccterm", "Components", "DisplayModels"], files: sources,
    repoModules: Set(modules.map(\.name)))
let ruleFindings = rules.findings()
try rules.render(header: "# Rules — where code lives and component boundaries").write(
    to: outDir.appendingPathComponent("rules.md"), atomically: true, encoding: .utf8)
indexText += "\n## Rules\n\n- [rules.md](rules.md) — \(ruleFindings.count) findings "
indexText += "against `macos/CLAUDE.md` § Where code lives and § Component boundaries, each with its fix\n"
try Tree(index: index, rules: rules).render(header: "# Component tree").write(
    to: outDir.appendingPathComponent("tree.md"), atomically: true, encoding: .utf8)
indexText += "- [tree.md](tree.md) — the component tree from the composition root\n"
try indexText.write(to: outDir.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
for unit in units {
    try renderer.renderUnit(unit).write(
        to: outDir.appendingPathComponent(Renderer.fileName(ofUnit: unit)), atomically: true, encoding: .utf8)
}
print("arch map (\(scopeArg)): \(units.count) units → \(outDir.path)/index.md")
print("rules: \(ruleFindings.count) findings → \(outDir.path)/rules.md")
for line in rules.summary() { print("  " + line) }
