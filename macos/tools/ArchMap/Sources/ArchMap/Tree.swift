import Foundation

/// `tree.md`: the component tree from the composition root — which window,
/// controller and view builds or holds which, across the app and the packages,
/// with what each is shown and what it reports. A type that builds components
/// without being one (a coordinator, `TranscriptTab`, `PageRow+View`) is a node
/// too, or the subtree it builds would hang from nothing.
struct Tree {
    let index: Index
    let rules: Rules

    private var byID: [ObjectIdentifier: TypeInfo] {
        Dictionary(uniqueKeysWithValues: index.types.map { (ObjectIdentifier($0), $0) })
    }

    /// Builds components without being one: constructs one, or — in the app,
    /// where a factory makes them generically (`PageRow+View`'s `V()`) — names one.
    private func isFactory(_ type: TypeInfo) -> Bool {
        guard !["file", "protocol"].contains(type.kind), !rules.isComponent(type) else { return false }
        let names = type.creates + (type.module == Placement.app ? type.typeRefs.sorted() : [])
        return names.contains { index.lookup($0, from: type).map { rules.isComponent($0) } ?? false }
    }

    /// The app's extensions of a type declared elsewhere (`SettingsSplitViewController.Pane+SettingsPane`).
    private func foreignExtensions(of type: TypeInfo) -> [TypeInfo] {
        index.types.filter { $0.extends === type }
    }

    /// Engines are drawn as one node: the app reaches them through their surface.
    private func isExpanded(_ type: TypeInfo) -> Bool {
        [Placement.app, "Components"].contains(type.module)
    }

    /// What `owner` builds, holds or builds through, in the order it names them.
    func children(of owner: TypeInfo) -> [TypeInfo] {
        let built = rules.children(of: owner)
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(owner)]
        var result: [TypeInfo] = []
        let held = owner.properties.compactMap(\.type)
        // A factory builds what it names, however it constructs it.
        let buildsNamed = owner.module == Placement.app && isFactory(owner)
        for text in owner.creates + held + owner.typeRefs.sorted() {
            for word in words(text) {
                guard let type = index.lookup(word, from: owner), seen.insert(ObjectIdentifier(type)).inserted
                else { continue }
                // A factory named, not called, hangs under a view that uses it
                // (the split opening tabs), not under the root that passes it on.
                let usesFactory = isFactory(type) && !isRoot(owner) && (rules.isComponent(owner) || isFactory(owner))
                if built.contains(ObjectIdentifier(type))
                    || (!index.isSelfOrNested(type, of: owner)
                        && (usesFactory || (buildsNamed && rules.isComponent(type))))
                {
                    result.append(type)
                }
                // An extension's factory builds under its own module's types, or
                // under the type that holds what it makes (a split holds its panes).
                let holds = held.contains { words($0).contains(word) }
                for ext in foreignExtensions(of: type)
                where ext !== owner && (ext.module == owner.module || holds) && isFactory(ext) {
                    if seen.insert(ObjectIdentifier(ext)).inserted { result.append(ext) }
                }
            }
        }
        // Held but named nowhere above (a lazy property's closure).
        for id in built where seen.insert(id).inserted { if let type = byID[id] { result.append(type) } }
        return result
    }

    /// The composition root: what it builds, it builds for others to place.
    private func isRoot(_ type: TypeInfo) -> Bool {
        type.module == Placement.app && type.kind == "class" && type.inherits.contains("NSApplicationDelegate")
    }

    private func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "." }).map(String.init)
    }

    // MARK: What a node is shown and reports

    /// The stores and services a type holds, the display models it reads, and
    /// the protocols and closures it reports through.
    private func notes(of type: TypeInfo) -> String {
        var parts: [String] = []
        let held = type.properties.compactMap { index.propertyType($0, in: type) }
        let built = unique(type.creates.compactMap { index.lookup($0, from: type) }.filter(isStore).map(\.shortName))
        let stores = unique(held.filter { $0.module == "ccterm" && isStore($0) }.map(\.shortName))
            .filter { !built.contains($0) }
        if !stores.isEmpty { parts.append("reads " + stores.joined(separator: ", ")) }
        if !built.isEmpty { parts.append("builds " + built.joined(separator: ", ")) }
        let shown = unique(
            type.typeRefs.sorted().compactMap { index.lookup($0, from: type) }
                .filter { $0.module == "DisplayModels" && $0.kind != "extension" }.map(\.name))
        if !shown.isEmpty { parts.append("shows " + abbreviate(shown)) }
        var reports: [String] = []
        for property in type.properties where !property.isStatic && !property.isPrivate {
            guard let text = property.type else { continue }
            if property.name == "delegate" || property.name.hasSuffix("Delegate") {
                reports.append(index.coreName(text) ?? text)
            } else if text.contains("->") {
                reports.append(property.name)
            }
        }
        if !reports.isEmpty { parts.append("reports " + unique(reports).joined(separator: ", ")) }
        return parts.isEmpty ? "" : " — " + parts.joined(separator: " · ")
    }

    private func isStore(_ type: TypeInfo) -> Bool {
        type.kind != "extension" && ["Store", "Service"].contains { type.shortName.hasSuffix($0) }
    }

    private func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    private func abbreviate(_ names: [String]) -> String {
        names.count <= 4 ? names.joined(separator: ", ") : names.prefix(4).joined(separator: ", ") + ", …"
    }

    // MARK: Render

    func render(header: String) -> String {
        let roots = index.types.filter(isRoot)
        var out = header + "\n\n"
        out += "How to read: each line is a type that builds or holds the ones indented under it — a window, a "
        out += "controller, a view, or a type that builds them (a coordinator, a factory). `[module]` says where it "
        out += "lives; *reads* the stores and services it holds, *builds* the ones it makes, *shows* the display "
        out += "models it names, *reports* its delegate and callbacks. A type sits under the nearest type that "
        out += "builds or holds it; anywhere else it is named with ↑.\n"
        // Breadth first, so a type sits under its nearest builder, not under
        // the first one a depth-first walk happens to meet.
        var placed = Set(roots.map(ObjectIdentifier.init))
        var kidsOf: [ObjectIdentifier: [(type: TypeInfo, isOwn: Bool)]] = [:]
        var queue = roots
        while !queue.isEmpty {
            let type = queue.removeFirst()
            guard isExpanded(type) else { continue }
            for kid in children(of: type) {
                let isOwn = placed.insert(ObjectIdentifier(kid)).inserted
                kidsOf[ObjectIdentifier(type), default: []].append((kid, isOwn))
                if isOwn { queue.append(kid) }
            }
        }
        var lines: [String] = []
        func walk(_ type: TypeInfo, isOwn: Bool, prefix: String, last: Bool, isRoot: Bool) {
            let branch = isRoot ? "" : (last ? "└─ " : "├─ ")
            let module = type.extends == nil ? type.module : type.module + " extension"
            lines.append(prefix + branch + "\(type.name) [\(module)]" + (isOwn ? notes(of: type) : " ↑"))
            guard isOwn else { return }
            let kids = kidsOf[ObjectIdentifier(type)] ?? []
            let childPrefix = isRoot ? "" : prefix + (last ? "   " : "│  ")
            for (offset, kid) in kids.enumerated() {
                walk(kid.type, isOwn: kid.isOwn, prefix: childPrefix, last: offset == kids.count - 1, isRoot: false)
            }
        }
        for root in roots { walk(root, isOwn: true, prefix: "", last: true, isRoot: true) }
        let expanded = placed
        out += "\n```\n" + lines.joined(separator: "\n") + "\n```\n"
        let unreached = index.types.filter {
            ["ccterm", "Components"].contains($0.module) && rules.isComponent($0)
                && !expanded.contains(ObjectIdentifier($0)) && !$0.file.contains("/ComponentsDesign/")
        }
        .map(\.name).sorted()
        out += "\n## Components no root reaches (\(unreached.count))\n\n"
        out += "Built only by the style page or a test, or by nothing: each is dead code or a missing edge.\n\n"
        out += unreached.isEmpty ? "- none\n" : unreached.map { "- `\($0)`" }.joined(separator: "\n") + "\n"
        return out
    }
}
