import Foundation

/// Markdown for the map: `index.md` (modules, units, cross-unit edges and
/// flows, cycles) and one `<unit>.md` per unit (each type's shape,
/// dependencies, data flow, and who outside the unit uses it).
struct Renderer {
    let index: Index
    let files: [SourceFile]
    /// Units to write; the rest of the parsed universe only feeds resolution.
    let units: [String]
    let header: String

    private static let streamMarkers = [
        "AsyncStream", "AsyncThrowingStream", "AnyPublisher", "Publisher<", "Subject<", "PassthroughSubject",
        "CurrentValueSubject",
    ]
    private static let swiftUIWrappers: Set<String> = [
        "@State", "@Binding", "@Environment", "@Bindable", "@ObservedObject", "@StateObject", "@EnvironmentObject",
        "@AppStorage", "@FocusState", "@SceneStorage",
    ]

    static func fileName(ofUnit unit: String) -> String { unit.replacingOccurrences(of: "/", with: ".") + ".md" }

    private func types(in unit: String) -> [TypeInfo] {
        index.types.filter { $0.unit == unit }.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    // MARK: index.md

    func renderIndex() -> String {
        var out = [header, "", Self.legend, ""]
        let inScope = Set(units)

        out.append("## Modules")
        for module in Set(files.filter { inScope.contains($0.unit) }.map(\.module)).sorted() {
            let moduleFiles = files.filter { $0.module == module }
            let imports = Set(moduleFiles.flatMap(\.imports)).subtracting([module])
            let internalImports = imports.filter { index.modules.contains($0) }.sorted()
            let frameworks = imports.subtracting(internalImports).sorted()
            let lines = moduleFiles.reduce(0) { $0 + $1.lines }
            out.append(
                "- **\(module)** — \(lines) lines · imports modules: \(list(internalImports)) · frameworks: \(list(frameworks))"
            )
        }

        out += [
            "", "## Units", "", "| unit | files | lines | types | depends on units | used by units |",
            "|---|---|---|---|---|---|",
        ]
        for unit in units {
            let unitFiles = files.filter { $0.unit == unit }
            let typeCount = types(in: unit).filter { $0.kind != "file" && $0.kind != "extension" }.count
            out.append(
                "| [\(unit)](\(Self.fileName(ofUnit: unit))) | \(unitFiles.count) | \(unitFiles.reduce(0) { $0 + $1.lines }) | \(typeCount) | \(list(dependencies(of: unit).keys.sorted())) | \(list(users(of: unit).sorted())) |"
            )
        }

        out += ["", "## Cross-unit data flow", "", "Consumer unit ⟵ producer unit: flow (consuming type)."]
        var flowLines: [String] = []
        for unit in units {
            for type in types(in: unit) {
                for flow in resolvedFlows(of: type) {
                    // A publisher handed to an init feeds the constructed type, wired by this one.
                    let consumer = flow.into?.unit ?? unit
                    guard let source = flow.source, source.unit != consumer else { continue }
                    let by = flow.into == nil ? type.name : "wired by \(type.name)"
                    flowLines.append("- \(consumer) ⟵ \(source.unit): \(flow.kind) `\(flow.text)` (\(by))")
                }
            }
        }
        out += flowLines.isEmpty ? ["- none"] : flowLines

        out += ["", "## Notifications", ""]
        var notes: [String] = []
        for unit in units {
            for type in types(in: unit) {
                for flow in type.flows where flow.kind == .notifyPost || flow.kind == .notifyObserve {
                    notes.append("- \(flow.kind.rawValue) `\(flow.detail ?? "?")` — \(type.name) (\(unit))")
                }
            }
        }
        out += notes.isEmpty ? ["- none"] : Array(Set(notes)).sorted()

        out += ["", "## Cycles", ""]
        let unitCycles = Index.cycles(units) { dependencies(of: $0).keys.filter(inScope.contains) }
        out.append(
            "- unit cycles: "
                + (unitCycles.isEmpty
                    ? "none" : unitCycles.map { $0.sorted().joined(separator: " ⇄ ") }.joined(separator: "; ")))
        let scopedTypes = index.types.filter {
            inScope.contains($0.unit) && $0.kind != "file" && $0.kind != "extension"
        }
        let ids = Dictionary(uniqueKeysWithValues: scopedTypes.map { (ObjectIdentifier($0), $0) })
        let typeCycles = Index.cycles(scopedTypes.map(ObjectIdentifier.init)) { id in
            (index.deps[id] ?? []).map(ObjectIdentifier.init).filter { ids[$0] != nil }
        }
        // `Foo ⇄ FooDelegate` alone is the Cocoa delegate idiom, not a finding.
        let meaningful = typeCycles.map { $0.compactMap { ids[$0] } }.filter { cycle in
            !(cycle.count == 2 && (cycle[0].name.hasPrefix(cycle[1].name) || cycle[1].name.hasPrefix(cycle[0].name)))
        }
        out.append("- type cycles: " + (meaningful.isEmpty ? "none" : ""))
        for cycle in meaningful { out.append("  - " + cycle.map(\.name).sorted().joined(separator: " ⇄ ")) }

        let unreferenced = scopedTypes.filter(isUnreferenced).map { "\($0.name) (\($0.unit))" }
        out += [
            "", "## Unreferenced top-level types", "", "Named by no other type anywhere (tests aren't parsed):", "",
        ]
        out += unreferenced.isEmpty ? ["- none"] : unreferenced.map { "- " + $0 }
        return out.joined(separator: "\n") + "\n"
    }

    private static let legend = """
        How to read: a **unit** is one source directory (`<module>/<subdirs>`). Each unit file lists its \
        types with only architecture-relevant facts — declaration, init (= injected dependencies), \
        state it owns, what it **emits** (published values, streams, callbacks, delegates) and **consumes** \
        (`sink`, `for-await`, `observes` = withObservationTracking, `swiftui-reads` = SwiftUI body reading an \
        @Observable, `notified-by`, `kvo`), what it **wires** on others (`sets-callback`, `sets-delegate`, `passes` = hands a publisher or stream to what it constructs), \
        what it **creates**, `.shared` singletons it reaches for, and **used by** = which other units touch it \
        and through which of its own members (`init` = constructs it); **internal, used only inside** = members nothing but the type itself touches (candidates for `private`); **minor types** = private or nested types with no data-flow role, \
        named only. Used-by counts every target — demo and \
        smoke executables too, even outside the scope; tests are not parsed. Names resolve only within a \
        file's module and its imports. Receivers are resolved to types where the map can \
        (`LibraryStore.$nodes`); otherwise the raw expression is kept. Resolution is syntactic: treat \
        absences as likely, not proven.
        """

    // MARK: Unit relations

    /// Unit → the types in it this unit depends on.
    private func dependencies(of unit: String) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for type in types(in: unit) {
            for dep in index.deps[ObjectIdentifier(type)] ?? [] where dep.unit != unit {
                result[dep.unit, default: []].insert(dep.name)
            }
        }
        return result
    }

    private func isUnreferenced(_ type: TypeInfo) -> Bool {
        !type.name.contains(".") && !type.attributes.contains("@main") && !["file", "extension"].contains(type.kind)
            && (index.referencedBy[ObjectIdentifier(type)] ?? []).isEmpty
    }

    /// Private or nested types with no data-flow role: named on one line, not given an entry.
    private func isMinor(_ type: TypeInfo, facts: [String]) -> Bool {
        guard ["private", "fileprivate"].contains(type.access) || type.name.contains(".") else { return false }
        let flowLabels = [
            "- state:", "- emits:", "- consumes:", "- notified-by:", "- wires:", "- singletons:", "- used by:",
        ]
        return !facts.contains { line in flowLabels.contains { line.hasPrefix($0) } }
    }

    private func users(of unit: String) -> Set<String> {
        Set(types(in: unit).flatMap { (index.usedBy[ObjectIdentifier($0)] ?? [:]).keys })
    }

    // MARK: <unit>.md

    func renderUnit(_ unit: String) -> String {
        let unitFiles = files.filter { $0.unit == unit }.sorted { $0.path < $1.path }
        let unitTypes = types(in: unit)
        var out = [
            "# \(unit)", "",
            "\(unitFiles.count) files · \(unitFiles.reduce(0) { $0 + $1.lines }) lines · directory `macos/\(unitFiles.first.map { ($0.path as NSString).deletingLastPathComponent } ?? "")`",
            "",
            "Files: "
                + unitFiles.map {
                    "\(($0.path as NSString).lastPathComponent) (\($0.imports.joined(separator: ", ")))"
                }.joined(separator: " · "),
        ]
        let deps = dependencies(of: unit)
        out.append("")
        out.append(
            "Depends on: "
                + (deps.isEmpty
                    ? "—"
                    : deps.keys.sorted().map { "\($0) {\(deps[$0]!.sorted().joined(separator: ", "))}" }.joined(
                        separator: " · ")))
        out.append("Used by: " + list(users(of: unit).sorted()))
        var minor: [String] = []
        var entries: [String] = []
        for type in unitTypes {
            let typeFacts = facts(type)
            if isMinor(type, facts: typeFacts) {
                minor.append("\(type.name) (\(type.kind), \(type.lines)L)")
            } else {
                entries += [""] + renderType(type, facts: typeFacts)
            }
        }
        if !minor.isEmpty {
            out.append("Minor types: " + minor.joined(separator: ", "))
        }
        return (out + entries).joined(separator: "\n") + "\n"
    }

    private func renderType(_ type: TypeInfo, facts: [String]) -> [String] {
        let fileName = (type.file as NSString).lastPathComponent
        let adds = (type.members.map(\.name) + type.properties.filter { !$0.isPrivate }.map(\.name))
        let addsLine =
            adds.isEmpty ? [] : ["- adds: " + Array(NSOrderedSet(array: adds)).map { "\($0)" }.joined(separator: ", ")]
        if type.kind == "file" {
            return ["### file scope of \(fileName)"] + addsLine + facts
        }
        if type.kind == "extension" {
            return [
                "### extension \(type.name)\(type.inherits.isEmpty ? "" : " : " + type.inherits.joined(separator: ", ")) · \(fileName)"
            ]
                + addsLine + facts
        }
        var decl =
            (type.attributes
            + type.modifiers.filter {
                !["public", "internal", "private", "fileprivate", "package", "open"].contains($0)
            } + [type.kind, type.name])
            .joined(separator: " ")
        if !type.inherits.isEmpty { decl += " : " + type.inherits.joined(separator: ", ") }
        return ["### \(decl)", "\(type.access) · \(type.lines)L · \(fileName):\(type.line)"] + facts
    }

    private func facts(_ type: TypeInfo) -> [String] {
        var lines: [String] = []
        func add(_ label: String, _ items: [String]) {
            if !items.isEmpty { lines.append("- \(label): " + items.joined(separator: " · ")) }
        }
        let instanceStored = type.properties.filter { !$0.isStatic && !$0.isComputed }

        if !type.nested.isEmpty { add("nested", [type.nested.joined(separator: ", ")]) }
        add("init", type.inits)
        if let units = index.extendedIn[ObjectIdentifier(type)] { add("extended in", units.sorted()) }

        var state: [String] = []
        if type.isObservable {
            let tracked = instanceStored.filter {
                !$0.isLet && !$0.isPrivate && !$0.wrappers.contains("@ObservationIgnored")
            }
            if !tracked.isEmpty { state.append("@Observable " + tracked.map(\.name).joined(separator: ", ")) }
        }
        state += type.properties.filter { $0.wrappers.contains { Self.swiftUIWrappers.contains($0) } }
            .map { "\($0.wrappers.joined(separator: " ")) \($0.name)\($0.type.map { ": " + $0 } ?? "")" }
        add("state", state)

        var emits: [String] = type.properties.filter { $0.wrappers.contains("@Published") }
            .map { "@Published \($0.name)\($0.type.map { ": " + $0 } ?? "")" }
        emits += type.properties.filter { p in
            !p.isPrivate && Self.streamMarkers.contains { p.type?.contains($0) == true }
        }
        .map { "stream \($0.name): \($0.type!)" }
        emits += type.members.filter { m in
            !["private", "fileprivate"].contains(m.access)
                && Self.streamMarkers.contains { m.returnType?.contains($0) == true }
        }
        .map { "stream \($0.name)(…) -> \($0.returnType!)" }
        emits += type.properties.filter { !$0.isStatic && !$0.isPrivate && $0.type?.contains("->") == true }
            .map { "callback \($0.name): \($0.type!)" }
        emits += type.properties.filter { $0.modifiers.contains("weak") && $0.name.lowercased().contains("delegate") }
            .map { "delegate \($0.name): \($0.type ?? "?")" }
        emits += type.flows.filter { $0.kind == .notifyPost }.map { "posts \($0.detail ?? "?")" }
        add("emits", Array(NSOrderedSet(array: emits)) as! [String])

        let flows = resolvedFlows(of: type)
        add(
            "consumes",
            flows.filter { ["sink", "for-await", "observes", "swiftui-reads", "kvo"].contains($0.kind) }.map {
                "\($0.kind) \($0.text)"
            })
        add("notified-by", type.flows.filter { $0.kind == .notifyObserve }.map { $0.detail ?? "?" })
        add(
            "wires",
            flows.filter { ["sets-callback", "sets-delegate", "passes"].contains($0.kind) }.map {
                "\($0.kind) \($0.text)"
            })

        let holds = instanceStored.compactMap { p -> String? in
            guard let target = index.propertyType(p, in: type), !index.isSelfOrNested(target, of: type),
                !p.wrappers.contains(where: Self.swiftUIWrappers.contains)
            else { return nil }
            var flags = p.modifiers.filter { ["weak", "unowned", "lazy", "private", "fileprivate"].contains($0) }
            if type.initParams.contains(p.name) { flags.append("injected") }
            return "\(p.name): \(target.name)" + (flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))")
        }
        add("holds", holds)

        let created = Set(
            type.creates.compactMap { index.lookup($0, from: type) }.filter { !index.isSelfOrNested($0, of: type) }.map(
                \.name))
        add("creates", created.sorted() + type.hosts.map { "hosting(\($0))" })
        let singletons = Set(
            type.accesses.filter { $0.name == "shared" }.compactMap { access -> String? in
                guard let target = index.typeOf(access.base, scope: access.scope, owner: type), target !== type else {
                    return nil
                }
                return target.name + ".shared"
            })
        add("singletons", singletons.sorted())
        if type.properties.contains(where: { $0.isStatic && $0.name == "shared" }) {
            add("is singleton", ["static shared"])
        }
        if type.tasks > 0 { add("tasks", ["\(type.tasks) Task {…}"]) }

        let deps = (index.deps[ObjectIdentifier(type)] ?? [])
        add("deps", deps.map { $0.unit == type.unit ? $0.name : "\($0.name) [\($0.unit)]" })
        let usedBy = index.usedBy[ObjectIdentifier(type)] ?? [:]
        add(
            "used by",
            usedBy.keys.sorted().map { unit in
                let members = usedBy[unit]!.sorted()
                return members.isEmpty ? unit : "\(unit) (\(members.joined(separator: ", ")))"
            })
        if isUnreferenced(type) { add("unreferenced", ["no other type names it"]) }
        add("public, unused outside module", index.unusedPublicMembers(of: type))
        add("internal, used only inside", index.internalMembersUsedOnlyInside(type))
        return lines
    }

    /// One flow of a type with its receiver resolved: the producing type
    /// (`source`), and for `passes` the type it is handed to (`into`).
    struct ResolvedFlow {
        let kind: String
        let text: String
        let source: TypeInfo?
        var into: TypeInfo? = nil
    }

    /// Every flow of a type, receivers resolved; `passes` only for what
    /// resolves to a `$published` value or a stream-typed member.
    func resolvedFlows(of type: TypeInfo) -> [ResolvedFlow] {
        var result: [ResolvedFlow] = []
        var seen: Set<String> = []
        for flow in type.flows where flow.kind != .notifyPost && flow.kind != .notifyObserve {
            guard let (text, source) = index.describe(flow.subject, scope: flow.scope, owner: type) else { continue }
            var rendered = flow.detail.map { "\(text) \($0)" } ?? text
            var into: TypeInfo?
            if let target = flow.target {
                guard isStream(text, from: source) else { continue }
                into = index.lookup(target.type, from: type)
                rendered += " → \(target.type)(\(target.label):)"
            }
            if seen.insert(flow.kind.rawValue + rendered).inserted {
                result.append(
                    ResolvedFlow(
                        kind: flow.kind.rawValue, text: rendered, source: source === type ? nil : source, into: into))
            }
        }
        if type.isSwiftUIView {
            for access in type.accesses {
                guard let target = index.typeOf(access.base, scope: access.scope, owner: type), target.isObservable,
                    target !== type
                else { continue }
                let text = "\(target.name).\(access.name)"
                if access.name != "shared", seen.insert("swiftui-reads" + text).inserted {
                    result.append(ResolvedFlow(kind: "swiftui-reads", text: text, source: target))
                }
            }
        }
        return result
    }

    /// `Type.$name`, or `Type.name(…)` / `Type.name` declared stream-typed on `source`.
    private func isStream(_ text: String, from source: TypeInfo?) -> Bool {
        let last = text.split(separator: ".").last.map { String($0.prefix { $0 != "(" }) } ?? ""
        if last.hasPrefix("$") { return true }
        guard let source else { return false }
        let declared =
            source.members.first { $0.name == last }?.returnType ?? source.properties.first { $0.name == last }?.type
        return Self.streamMarkers.contains { declared?.contains($0) == true }
    }

    private func list(_ items: [String]) -> String { items.isEmpty ? "—" : items.joined(separator: ", ") }
}
