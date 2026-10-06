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
let scopeIsDefault = args.count <= 3 || args[3].isEmpty
let scopeArg = scopeIsDefault ? "core" : args[3]
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
    // A type's name (`TranscriptViewController`) selects the unit it is declared in.
    if let type = index.types.first(where: { $0.kind != "extension" && ($0.name == token || $0.shortName == token) }) {
        return sources.filter { $0.unit == type.unit }
    }
    let tail = "/" + path.lowercased()
    return sources.filter { file in
        let unit = file.unit.lowercased()
        return unit.hasSuffix(tail) || unit == path.lowercased() || unit.contains(tail + "/")
    }
}

let index = Index(files: sources)

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
let stamp = "Generated from `\(git("rev-parse", "--short", "HEAD"))`\(dirty) by `make arch`; never edit by hand."
try? fm.removeItem(at: outDir)
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
@MainActor func write(_ text: String, to name: String) throws {
    let url = outDir.appendingPathComponent(name)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

// The app's placement, tree and data, whatever the scope: a scope picks what
// the unit map describes, while these are facts about the app as a whole.
let rules = Rules(
    index: index, modules: ["ccterm", "Components", "DisplayModels"], files: sources,
    repoModules: Set(modules.map(\.name)))
let ruleFindings = rules.findings()
try write(rules.render(header: "# Rules — where code lives and component boundaries"), to: "rules.md")
let tree = Tree(index: index, rules: rules)
try write(tree.render(header: "# Component tree"), to: "tree.md")
let renderer = Renderer(
    index: index, files: sources, units: units,
    header: "# Unit map — scope `\(scopeArg)`\n\n\(stamp) \(units.count) units · "
        + "\(sources.filter { scopedPaths.contains($0.path) }.reduce(0) { $0 + $1.lines }) lines.",
    places: { tree.placement(of: $0) })
let members = MemberMap(index: index, files: sources)
let dataMap = DataMap(index: index, rules: rules, renderer: renderer, members: members)
try write(dataMap.render(header: "# Data dependencies — the app's binders and stores"), to: "data.md")

// The unit map /arch-review reads: only for a scope asked for.
let writesUnits = !scopeIsDefault || detail == "members"
if writesUnits {
    var unitIndex = renderer.renderIndex()
    for unit in units { try write(renderer.renderUnit(unit), to: "units/" + Renderer.fileName(ofUnit: unit)) }
    if detail == "members" {
        unitIndex += "\n## Member maps\n\n"
        for unit in units {
            let name = Renderer.fileName(ofUnit: unit).replacingOccurrences(of: ".md", with: ".members.md")
            try write(members.render(unit: unit, header: "# \(unit) — members"), to: "units/" + name)
            unitIndex += "- [\(unit)](\(name))\n"
        }
    }
    try write(unitIndex, to: "units/index.md")
}

let summary = rules.summary()
let ruleCounts = summary.isEmpty ? "" : ": " + summary.joined(separator: " · ")
let unitLine: String
if writesUnits {
    unitLine =
        "- [units/index.md](units/index.md) — the unit map for scope `\(scopeArg)`: per source directory, "
        + "its types' dependencies, data flow and surface (what /arch-review reads)"
} else {
    unitLine = "- the unit map /arch-review reads: `make arch SCOPE=<core|app|kit|sdk|dir|unit>`"
}
var overview: [String] = ["# Architecture", "", stamp, ""]
overview += [
    "Read in levels: this page, then the three maps below, then one unit at a time — "
        + "`make arch SCOPE=<TypeName>` writes the unit map of the directory that type lives in "
        + "(its types' state, flows, surface and placement) to `units/`.",
    "", "## Top of the tree", "",
    "The composition root's components, opened while a subtree holds more than ten types: how many hang below each, the rule breaks "
        + "and binder-kept values in that subtree, and the stores it reads. Look where the counts are.", "",
]
overview += tree.outline(depth: 5, findings: ruleFindings, keeps: { dataMap.keptCount($0) })
overview += ["", "## Maps", ""]
overview.append(
    "- [tree.md](tree.md) — the component tree from `AppDelegate`: who builds or holds whom, what each reads, "
        + "shows and reports")
overview.append(
    "- [data.md](data.md) — the data dependencies: per binder, what it takes from the stores, shows each "
        + "component and does with what it reports; per store, who reads and calls it")
overview.append(
    "- [rules.md](rules.md) — \(ruleFindings.count) breaks of `macos/CLAUDE.md` § Where code lives and "
        + "§ Component boundaries" + ruleCounts)
overview += [unitLine, "", "## Modules", "", "Each library and the repo's modules it imports.", ""]
for module in modules where module.isLibrary {
    let files = sources.filter { $0.module == module.name }
    let imports = Set(files.flatMap(\.imports)).intersection(modules.map(\.name)).subtracting([module.name])
    let lines = files.reduce(0) { $0 + $1.lines }
    let arrow = imports.isEmpty ? "—" : imports.sorted().joined(separator: ", ")
    overview.append("- **\(module.name)** → \(arrow) · \(lines) lines")
}
try write(overview.joined(separator: "\n") + "\n", to: "index.md")

print("arch: \(outDir.path)/index.md — tree.md, data.md, rules.md" + (writesUnits ? ", units/ (\(units.count))" : ""))
print("rules: \(ruleFindings.count) findings → \(outDir.path)/rules.md")
for line in rules.summary() { print("  " + line) }
