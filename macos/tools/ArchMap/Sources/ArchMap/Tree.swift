import Foundation

/// `tree.md`: the component tree from the composition root — which window,
/// controller and view builds or holds which, across the app and the packages,
/// with what each is shown and what it reports. A type that builds components
/// without being one (a coordinator, `TranscriptTab`, `PageRow+View`) is a node
/// too, or the subtree it builds would hang from nothing.
struct Tree {
    let index: Index
    let rules: Rules
    /// What each view controller does per phase.
    var lifecycle: Lifecycle? = nil

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

    /// How `owner` has `kid` when it neither constructs it nor keeps it strongly:
    /// `weak` (a back-reference, not ownership) or `named only` (a static factory it
    /// calls, a type it builds through) — nil for built or strongly held.
    private func relation(of kid: TypeInfo, under owner: TypeInfo) -> String? {
        if owner.creates.contains(where: { index.lookup($0, from: owner) === kid }) { return nil }
        // An app factory builds the components it names (`PageRow+View`'s `V()`).
        if owner.module == Placement.app, isFactory(owner), rules.isComponent(kid) { return nil }
        let holding = owner.properties.filter { property in
            guard !property.isComputed, !property.isStatic else { return false }
            if index.propertyType(property, in: owner) === kid { return true }
            return words(property.type ?? "").contains { index.lookup($0, from: owner) === kid }
        }
        if holding.isEmpty { return kid.extends == nil ? "named only" : nil }
        let isWeak = holding.allSatisfy { $0.modifiers.contains("weak") || $0.modifiers.contains("unowned") }
        return isWeak ? "weak" : nil
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

    // MARK: Placement

    /// A button, field, box or line: a leaf the layout of a screen doesn't turn on.
    private func isControl(_ type: TypeInfo, depth: Int = 0) -> Bool {
        guard depth < 12 else { return false }
        return type.inherits.contains { parent in
            if parent.hasPrefix("NS") {
                return ["Button", "Control", "TextField", "Box", "ImageView", "ProgressIndicator"].contains {
                    parent.hasSuffix($0)
                }
            }
            guard let mapped = index.lookup(parent, from: type), mapped !== type else { return false }
            return isControl(mapped, depth: depth + 1)
        }
    }

    /// Where a type places what it lays out, in words, for its unit map: `transcript fills · composer
    /// bottom, above transcript`. Read off its anchor constraints and the splits and stacks it fills, one phrase
    /// per item — which side of the container, which sibling it is next to. Coarse on purpose:
    /// nothing is solved, constants are dropped.
    func placement(of type: TypeInfo) -> String? {
        let containers: Set<String> = [
            "", "self", "view", "contentView", "safeAreaLayoutGuide", "layoutMarginsGuide", "view.safeAreaLayoutGuide",
            "view.layoutMarginsGuide",
        ]
        func name(_ raw: String?) -> String? {
            guard var text = raw?.replacingOccurrences(of: "?", with: "").replacingOccurrences(of: "!", with: "")
            else { return nil }
            for prefix in ["self.", "Self."] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
            if let call = text.firstIndex(of: "(") { text = text[..<call] + "(…)" }
            if containers.contains(text) { return "" }
            for suffix in [".safeAreaLayoutGuide", ".layoutMarginsGuide", ".view"] where text.hasSuffix(suffix) {
                text.removeLast(suffix.count)
            }
            return text
        }
        // Only the parts that matter to the architecture: components, the
        // guides that carry a region between them, and split panes — not
        // each label and button.
        func isPart(_ item: String) -> Bool {
            let head = String(item.prefix { $0 != "." && $0 != "(" && $0 != "[" })
            guard let property = type.properties.first(where: { $0.name == head }) else { return false }
            if (property.type ?? "").contains("NSLayoutGuide") || (property.type ?? "").contains("SplitViewItem") {
                return true
            }
            guard let part = index.propertyType(property, in: type) else { return false }
            return rules.isComponent(part) && !isControl(part)
        }
        let sides: [String: String] = ["left": "leading", "right": "trailing"]
        var order: [String] = []
        var edges: [String: Set<String>] = [:]
        var phrases: [String: [String]] = [:]
        func add(_ item: String, _ phrase: String) {
            if !order.contains(item) { order.append(item) }
            if !(phrases[item] ?? []).contains(phrase) { phrases[item, default: []].append(phrase) }
        }
        for pin in type.pins {
            guard let item = name(pin.item), !item.isEmpty, pin.anchor == "split" || isPart(item) else { continue }
            let anchor = sides[pin.anchor] ?? pin.anchor
            if anchor == "split" {
                add(item, "a split pane")
                continue
            }
            if anchor == "stack" {
                add(item, "in " + (name(pin.other).flatMap { $0.isEmpty ? nil : $0 } ?? "a stack"))
                continue
            }
            guard let other = name(pin.other), let otherAnchor = pin.otherAnchor.map({ sides[$0] ?? $0 }) else {
                if ["width", "height"].contains(anchor) { add(item, "fixed " + anchor) }
                continue
            }
            if other.isEmpty {
                if !order.contains(item) { order.append(item) }
                edges[item, default: []].insert(anchor)
                continue
            }
            if other == item { continue }
            switch (anchor, otherAnchor) {
            case ("top", "bottom"): add(item, "below " + other)
            case ("bottom", "top"): add(item, "above " + other)
            case ("leading", "trailing"): add(item, "after " + other)
            case ("trailing", "leading"): add(item, "before " + other)
            case ("width", _), ("height", _): add(item, "\(anchor) of " + other)
            case ("centerX", _), ("centerY", _): add(item, "centred on " + other)
            default: break
            }
        }
        guard !order.isEmpty else { return nil }
        let parts = order.map { item -> String in
            let on = edges[item] ?? []
            let vertical =
                on.isSuperset(of: ["top", "bottom"])
                ? "full height"
                : on.contains("top")
                    ? "top"
                    : on.contains("bottom") ? "bottom" : on.contains("centerY") ? "middle" : nil
            let horizontal =
                on.isSuperset(of: ["leading", "trailing"])
                ? "full width"
                : on.contains("leading")
                    ? "leading" : on.contains("trailing") ? "trailing" : on.contains("centerX") ? "centre" : nil
            var side: String?
            switch (vertical, horizontal) {
            case ("full height", "full width"): side = "fills"
            case (let v?, "full width") where v != "full height": side = v
            case ("full height", let h?): side = h
            case let (v, h): side = [v, h].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            }
            return ([item + (side.map { " " + $0 } ?? "")] + (phrases[item] ?? [])).joined(separator: ", ")
        }
        let shown = parts.prefix(8).joined(separator: " · ")
        return parts.count > 8 ? shown + " · +\(parts.count - 8) more" : shown
    }

    typealias Kid = (type: TypeInfo, isOwn: Bool, relation: String?)

    /// Where each type sits: the types placed, and each owner's kids with whether it is their home.
    private func layout(_ roots: [TypeInfo]) -> (Set<ObjectIdentifier>, [ObjectIdentifier: [Kid]]) {
        // Breadth first, so a type sits under its nearest builder, not under
        // the first one a depth-first walk happens to meet.
        var placed = Set(roots.map(ObjectIdentifier.init))
        // A type sits under what builds or strongly holds it; a weak or named-only edge
        // places it only when no such owner reaches it.
        var edges: [ObjectIdentifier: [(type: TypeInfo, relation: String?)]] = [:]
        var home: [ObjectIdentifier: ObjectIdentifier] = [:]
        for strongOnly in [true, false] {
            var queue = index.types.filter { placed.contains(ObjectIdentifier($0)) }
            while !queue.isEmpty {
                let type = queue.removeFirst()
                guard isExpanded(type) else { continue }
                if edges[ObjectIdentifier(type)] == nil {
                    edges[ObjectIdentifier(type)] = children(of: type).map { ($0, relation(of: $0, under: type)) }
                }
                for kid in edges[ObjectIdentifier(type)] ?? [] where !strongOnly || kid.relation == nil {
                    guard placed.insert(ObjectIdentifier(kid.type)).inserted else { continue }
                    home[ObjectIdentifier(kid.type)] = ObjectIdentifier(type)
                    queue.append(kid.type)
                }
            }
        }
        var kidsOf: [ObjectIdentifier: [(type: TypeInfo, isOwn: Bool, relation: String?)]] = [:]
        for (owner, kids) in edges {
            kidsOf[owner] = kids.map { ($0.type, home[ObjectIdentifier($0.type)] == owner, $0.relation) }
        }
        return (placed, kidsOf)
    }

    /// The top of the tree for `index.md`: the root's components, opened down to `depth` while a subtree is big, each with what a
    /// reader can drill on — how much hangs below, the rule breaks and kept data in that subtree.
    func outline(depth: Int, findings: [Rules.Finding], keeps: (TypeInfo) -> Int) -> [String] {
        let roots = index.types.filter(isRoot)
        let (_, kidsOf) = layout(roots)
        func subtree(_ type: TypeInfo) -> [TypeInfo] {
            [type] + (kidsOf[ObjectIdentifier(type)] ?? []).filter(\.isOwn).flatMap { subtree($0.type) }
        }
        var lines: [String] = []
        func walk(_ type: TypeInfo, level: Int) {
            let all = subtree(type)
            let files = Set(all.map(\.file) + all.flatMap(\.extensionFiles))
            let breaks = findings.filter { files.contains($0.file) }.count
            let kept = all.map(keeps).reduce(0, +)
            var facts = ["\(all.count - 1) below"]
            if breaks > 0 { facts.append("\(breaks) rule breaks") }
            if kept > 0 { facts.append("keeps \(kept)") }
            let reads = notes(of: type).components(separatedBy: " · ").first { $0.contains("reads ") }
            if let reads { facts.append(reads.replacingOccurrences(of: " — ", with: "")) }
            lines.append(String(repeating: "  ", count: level) + "- `\(type.name)` — " + facts.joined(separator: " · "))
            guard level < depth, all.count > 10 else { return }
            for kid in kidsOf[ObjectIdentifier(type)] ?? [] where kid.isOwn && !kid.type.name.contains(".") {
                walk(kid.type, level: level + 1)
            }
        }
        for root in roots { walk(root, level: 0) }
        return lines
    }

    // MARK: Render

    func render(header: String) -> String {
        let roots = index.types.filter(isRoot)
        var out = header + "\n\n"
        out += "How to read: each line is a type that builds or holds the ones indented under it — a window, a "
        out += "controller, a view, or a type that builds them (a coordinator, a factory). `[module]` says where it "
        out +=
            "lives, given where it differs from the line it hangs from; *reads* the stores and services it holds, *builds* the ones it makes, *shows* the display "
        out += "models it names, *reports* its delegate and callbacks. A type sits under the nearest type that "
        out += "builds or strongly holds it; anywhere else it is named with ↑. An edge that is not ownership says "
        out += "so: *(weak)* a weak or unowned reference, *(named only)* a type it names or calls a static factory "
        out += "of, but neither builds nor holds.\n"
        let (placed, kidsOf) = layout(roots)
        var lines: [String] = []
        var controllers: [TypeInfo] = []
        func walk(
            _ type: TypeInfo, isOwn: Bool, relation: String?, prefix: String, last: Bool, isRoot: Bool,
            parentModule: String = ""
        ) {
            let branch = isRoot ? "" : (last ? "└─ " : "├─ ")
            let module = type.extends == nil ? type.module : type.module + " extension"
            let tag = module == parentModule ? "" : " [\(module)]"
            let how = relation.map { " (\($0))" } ?? ""
            lines.append(prefix + branch + type.name + tag + how + (isOwn ? notes(of: type) : " ↑"))
            guard isOwn else { return }
            if rules.isViewController(type) { controllers.append(type) }
            let kids = kidsOf[ObjectIdentifier(type)] ?? []
            let childPrefix = isRoot ? "" : prefix + (last ? "   " : "│  ")
            for (offset, kid) in kids.enumerated() {
                walk(
                    kid.type, isOwn: kid.isOwn, relation: kid.relation, prefix: childPrefix,
                    last: offset == kids.count - 1, isRoot: false, parentModule: module)
            }
        }
        for root in roots { walk(root, isOwn: true, relation: nil, prefix: "", last: true, isRoot: true) }
        let expanded = placed
        out += "\n```\n" + lines.joined(separator: "\n") + "\n```\n"
        let phases = controllers.compactMap { type in lifecycle?.summary(of: type.name).map { "- \(type.name): \($0)" }
        }
        if !phases.isEmpty {
            out += "\n## Lifecycle\n\n"
            out += "What each view controller does in each phase (`macos/CLAUDE.md` § Controllers & containment), "
            out += "through its own methods; a closure's body runs later and is left out. *builds* adds views, "
            out += "constraints or children, *subscribes* follows a publisher or notification, *measures* needs the "
            out += "laid-out size — which before `viewDidAppear` is a C1 break.\n\n"
            out += phases.joined(separator: "\n") + "\n"
        }
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

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
