import Foundation

/// `data.md`: the app's data dependencies — for each binder, what it takes
/// from the stores (subscribes, asks), what it shows each component, and what
/// it does with what a component reports; then each store's readers and
/// callers. The loop of `macos/CLAUDE.md` § Data down, events up, read off the
/// code.
struct DataMap {
    let index: Index
    let rules: Rules
    let renderer: Renderer
    let members: MemberMap

    private func isStore(_ type: TypeInfo) -> Bool {
        type.module == Placement.app && type.kind == "class"
            && ["Store", "Service"].contains { type.shortName.hasSuffix($0) }
    }

    /// The app's types that join stores to views: its components, its
    /// coordinators, and the composition root.
    private func isBinder(_ type: TypeInfo) -> Bool {
        type.module == Placement.app && type.kind == "class"
            && (rules.isComponent(type) || type.shortName.hasSuffix("Coordinator")
                || type.inherits.contains("NSApplicationDelegate"))
    }

    private var storeNames: Set<String> { Set(index.types.filter(isStore).map(\.shortName)) }

    /// The store members a member reaches, through the type's own members.
    private func storeCalls(from start: MemberMap.Member, in type: TypeInfo) -> [String] {
        let own = members.members[type.name] ?? []
        let stores = storeNames
        var found: [String] = []
        var seen: Set<String> = []
        var queue = [start]
        while !queue.isEmpty {
            let member = queue.removeFirst()
            guard seen.insert(member.signature).inserted else { continue }
            for call in member.calls {
                if let dot = call.firstIndex(of: "."), stores.contains(String(call[..<dot])) {
                    if !found.contains(call) { found.append(call) }
                } else if !call.contains(".") {
                    queue += own.filter { $0.name == call || $0.signature == call }
                }
            }
        }
        return found
    }

    /// Every store member the type calls, by store.
    private func asks(_ type: TypeInfo) -> [String: [String]] {
        var byStore: [String: Set<String>] = [:]
        for member in members.members[type.name] ?? [] {
            for call in member.calls {
                guard let dot = call.firstIndex(of: "."), storeNames.contains(String(call[..<dot])) else { continue }
                byStore[String(call[..<dot]), default: []].insert(String(call[call.index(after: dot)...]))
            }
        }
        return byStore.mapValues { $0.sorted() }
    }

    /// What a type follows: a store's value, or one handed to it in a context.
    private func subscriptions(_ type: TypeInfo) -> [(store: String, text: String)] {
        renderer.resolvedFlows(of: type).compactMap { flow in
            guard let source = flow.source, !["passes", "sets-callback", "sets-delegate"].contains(flow.kind)
            else { return nil }
            return (source.shortName, "\(flow.text) (\(flow.kind))")
        }
    }

    /// A store's value a type hands on, into what it builds (a context).
    private func passes(_ type: TypeInfo, from store: TypeInfo? = nil) -> [String] {
        renderer.resolvedFlows(of: type).filter { $0.kind == "passes" && (store == nil || $0.source === store) }
            .map(\.text)
    }

    /// What a component is shown: the display models it names.
    private func shown(_ type: TypeInfo) -> [String] {
        var seen: Set<String> = []
        return type.typeRefs.sorted().compactMap { index.lookup($0, from: type) }
            .filter { $0.module == "DisplayModels" && $0.kind != "extension" && !$0.name.contains(".") }
            .map(\.name).filter { seen.insert($0).inserted }
    }

    /// The protocols a binder answers for a view, with each method's store calls.
    private func hears(_ type: TypeInfo) -> [String] {
        var lines: [String] = []
        let own = members.members[type.name] ?? []
        for name in type.inherits {
            guard name.hasSuffix("Delegate") || name.hasSuffix("DataSource"),
                let proto = index.lookup(name, from: type), proto.kind == "protocol"
            else { continue }
            let required = Set(proto.members.map(\.name))
            var methods: [String] = []
            var quiet = 0
            for member in own where required.contains(member.name) {
                let calls = storeCalls(from: member, in: type)
                if calls.isEmpty {
                    quiet += 1
                } else {
                    methods.append("`\(member.signature)` → " + calls.joined(separator: ", "))
                }
            }
            if quiet > 0 {
                methods.append(methods.isEmpty ? "\(quiet) methods, none calls a store" : "\(quiet) more call none")
            }
            lines.append("\(proto.shortName): " + (methods.isEmpty ? "—" : methods.joined(separator: " · ")))
        }
        let callbacks = renderer.resolvedFlows(of: type).filter { $0.kind == "sets-callback" }.map(\.text)
        if !callbacks.isEmpty { lines.append("closures: " + callbacks.joined(separator: ", ")) }
        return lines
    }

    func render(header: String) -> String {
        var out = header + "\n\n"
        out += "How to read: data down, events up (`macos/CLAUDE.md` § Data down, events up). Per binder — the app's "
        out += "controllers, coordinators and root: *subscribes* the store values it follows, *asks* every store "
        out += "member it calls, *configures* the components it builds or holds with the display models they show, "
        out += "*hears* each protocol it answers for a view, each method with the store calls it leads to. Then per "
        out += "store, who reads and calls it. Calls are syntactic and follow the binder's own members only.\n"
        out += "\n## Binders\n"
        let binders = index.types.filter(isBinder).sorted { $0.name < $1.name }
        let byID = Dictionary(uniqueKeysWithValues: index.types.map { (ObjectIdentifier($0), $0) })
        for binder in binders {
            var section = ""
            for (store, text) in subscriptions(binder) { section += "- subscribes \(store): `\(text)`\n" }
            for text in passes(binder) { section += "- passes `\(text)`\n" }
            for (store, calls) in asks(binder).sorted(by: { $0.key < $1.key }) {
                section += "- asks \(store): " + calls.joined(separator: ", ") + "\n"
            }
            let configured = rules.children(of: binder).compactMap { byID[$0] }.filter { $0.module != Placement.app }
                .sorted { $0.name < $1.name }
            if !configured.isEmpty {
                let parts = configured.map { kid -> String in
                    let models = shown(kid)
                    return models.isEmpty ? kid.name : "\(kid.name) (\(models.joined(separator: ", ")))"
                }
                section += "- configures " + parts.joined(separator: " · ") + "\n"
            }
            for line in hears(binder) { section += "- hears \(line)\n" }
            if !section.isEmpty { out += "\n### \(binder.name)\n\n" + section }
        }
        out += "\n## Stores\n"
        for store in index.types.filter(isStore).sorted(by: { $0.name < $1.name }) {
            out += "\n### \(store.name)\n\n"
            var any = false
            for binder in index.types where binder.module == Placement.app && binder.kind != "file" {
                let subscribed = subscriptions(binder).filter { $0.store == store.shortName }.map(\.text)
                let called = asks(binder)[store.shortName] ?? []
                let handed = passes(binder, from: store)
                guard !subscribed.isEmpty || !called.isEmpty || !handed.isEmpty, binder !== store else { continue }
                any = true
                var parts: [String] = []
                if !subscribed.isEmpty {
                    parts.append("subscribes " + subscribed.map { "`\($0)`" }.joined(separator: ", "))
                }
                if !called.isEmpty { parts.append("calls " + called.joined(separator: ", ")) }
                if !handed.isEmpty { parts.append("passes " + handed.map { "`\($0)`" }.joined(separator: ", ")) }
                out += "- \(binder.name): " + parts.joined(separator: " · ") + "\n"
            }
            if !any { out += "- no reader in the app\n" }
        }
        return out
    }
}
