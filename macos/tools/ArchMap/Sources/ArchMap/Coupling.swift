import SwiftSyntax

/// The component-boundary rules of `macos/CLAUDE.md` § Component boundaries,
/// checked over the index: each finding names the rule, the place, and what to
/// do instead, so whoever reads `coupling.md` can fix it without re-deriving
/// the rule. A component is a class whose superclass chain reaches an AppKit
/// view, view controller, window controller or control. Rules apply to the
/// app's own components; a package's public API (TranscriptKit's
/// `contentInsets`) is a framework's and has its own rules.
struct Coupling {
    struct Finding {
        let rule: String
        let file: String
        let line: Int
        let what: String
    }

    let index: Index
    /// The app and the packages its components live in.
    let modules: Set<String>

    private static let rules: [String: (title: String, fix: String)] = [
        "B1": (
            "No geometry crosses a boundary",
            "Delete the member. The container that places both sets the child's `additionalSafeAreaInsets`; "
                + "the child reads its own `view.safeAreaInsets` / `safeAreaRect`. A region a child must publish is a "
                + "layout guide named for the child's own role, not for what fills it."
        ),
        "B2": (
            "Siblings never meet, not even through the container",
            "Don't feed one child from another. The source child reports the event up (delegate); the container "
                + "updates the one source of truth and configures both children from it — or, if the data is the "
                + "source child's own concern, move it inside that child."
        ),
        "B3": (
            "No reaching through a child",
            "Give the child a command of its own and call that, or send the action to `nil` (the responder chain) "
                + "instead of targeting the grandchild."
        ),
        "B4": (
            "A component names only what it builds or holds",
            "Move a shared value down into a shared type (`Drawing/`, the model) or report the event up through "
                + "the delegate; never name a parent's or sibling's type."
        ),
    ]

    private static let geometry: Set<String> = [
        "CGFloat", "NSRect", "CGRect", "NSSize", "CGSize", "NSPoint", "CGPoint", "NSEdgeInsets",
        "NSDirectionalEdgeInsets", "NSLayoutGuide", "NSLayoutConstraint", "NSLayoutYAxisAnchor",
        "NSLayoutXAxisAnchor", "NSLayoutDimension",
    ]

    // MARK: Components

    func isComponent(_ type: TypeInfo, depth: Int = 0) -> Bool {
        guard type.kind == "class", depth < 12 else { return false }
        for parent in type.inherits {
            if Self.isFrameworkComponent(parent) { return true }
            if let mapped = index.lookup(parent, from: type), mapped !== type, isComponent(mapped, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    private static func isFrameworkComponent(_ name: String) -> Bool {
        guard name.hasPrefix("NS") else { return false }
        return [
            "View", "ViewController", "WindowController", "Button", "Control", "TextField", "SearchField",
            "Switch", "Slider", "Box",
        ].contains { name.hasSuffix($0) }
    }

    /// What `owner` builds or holds: the components it constructs or keeps in
    /// a stored property.
    func children(of owner: TypeInfo) -> Set<ObjectIdentifier> {
        var found: Set<ObjectIdentifier> = []
        for name in owner.creates {
            if let type = index.lookup(name, from: owner), isComponent(type) { found.insert(ObjectIdentifier(type)) }
        }
        for property in owner.properties where !property.isComputed && !property.isStatic {
            if let type = index.propertyType(property, in: owner), isComponent(type) {
                found.insert(ObjectIdentifier(type))
            }
            // `[URL: MarkView]`, `[Row]`: the element is held too.
            if let text = property.type {
                for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) {
                    if let type = index.lookup(String(word), from: owner), isComponent(type) {
                        found.insert(ObjectIdentifier(type))
                    }
                }
            }
        }
        return found
    }

    struct Declared {
        let text: String
        /// A function of its arguments (`height(for:width:)`), not of an instance.
        let isStatic: Bool
        /// A stored `var` someone outside can set: an inbound value.
        let isSettable: Bool
        /// AppKit's own (`intrinsicContentSize`), not the type's chosen surface.
        let isOverride: Bool
    }

    /// The declared type of `member` on `type`: a property's type or a
    /// function's return type, as written.
    private func declaredType(of member: String, on type: TypeInfo) -> Declared? {
        if let property = type.properties.first(where: { $0.name == member }), let text = property.type {
            return Declared(
                text: text, isStatic: property.isStatic,
                isSettable: !property.isLet && !property.isComputed && !property.isPrivate
                    && !property.modifiers.contains("private(set)"),
                isOverride: property.modifiers.contains("override"))
        }
        if let function = type.members.first(where: { $0.name == member }), let returns = function.returnType {
            return Declared(
                text: returns, isStatic: function.isStatic, isSettable: false, isOverride: function.isOverride)
        }
        return nil
    }

    func isViewController(_ type: TypeInfo, depth: Int = 0) -> Bool {
        guard depth < 12 else { return false }
        return type.inherits.contains { parent in
            if parent.hasPrefix("NS") { return parent.hasSuffix("ViewController") }
            guard let mapped = index.lookup(parent, from: type), mapped !== type else { return false }
            return isViewController(mapped, depth: depth + 1)
        }
    }

    private func isOwn(_ member: String, of type: TypeInfo) -> Bool {
        type.members.contains { $0.name == member } || type.properties.contains { $0.name == member }
    }

    // MARK: Rules

    func findings() -> [Finding] {
        var found: [Finding] = []
        let components = index.types.filter { modules.contains($0.module) && isComponent($0) }
        let componentIDs = Set(components.map(ObjectIdentifier.init))
        for user in index.types where modules.contains(user.module) && user.kind != "file" {
            let userChildren = children(of: user)
            var byStatement: [SyntaxIdentifier: [(base: String, target: TypeInfo, access: Access)]] = [:]
            for access in user.accesses {
                guard let target = index.typeOf(access.base, scope: access.scope, owner: user),
                    componentIDs.contains(ObjectIdentifier(target)), !index.isSelfOrNested(target, of: user),
                    isOwn(access.name, of: target)
                else { continue }
                let declared = declaredType(of: access.name, on: target)
                let holds = userChildren.contains(ObjectIdentifier(target))
                // B1: geometry fed into a component (a settable size, inset or
                // guide), or read by one that doesn't hold it. A holder reading
                // its own child's natural size to lay it out is its job.
                if let declared, !declared.isStatic, !declared.isOverride, let core = index.coreName(declared.text),
                    Self.geometry.contains(core), declared.isSettable || !holds
                {
                    found.append(
                        Finding(
                            rule: "B1", file: user.file, line: access.line,
                            what: "`\(user.shortName)` uses `\(target.shortName).\(access.name): \(declared.text)`"))
                }
                // B3: a component inside the child, reached through it.
                if let declared, !declared.isOverride, let core = index.coreName(declared.text),
                    let inner = index.lookup(core, from: target), isComponent(inner),
                    !index.isSelfOrNested(inner, of: user)
                {
                    found.append(
                        Finding(
                            rule: "B3", file: user.file, line: access.line,
                            what: "`\(user.shortName)` reaches `\(inner.shortName)` through "
                                + "`\(target.shortName).\(access.name)`"))
                }
                if let statement = access.statement, userChildren.contains(ObjectIdentifier(target)) {
                    byStatement[statement, default: []].append(
                        (access.base.trimmedDescription, target, access))
                }
            }
            // B2: two children's own members in one statement — children with
            // their own lifecycle (a view controller among them). A view wiring
            // its own subviews together is composing itself.
            for (_, uses) in byStatement {
                let bases = Set(uses.map(\.base))
                guard bases.count >= 2,
                    isViewController(user) || uses.contains(where: { isViewController($0.target) }),
                    let first = uses.min(by: { $0.access.line < $1.access.line })
                else { continue }
                let names = uses.map { "`\($0.base).\($0.access.name)`" }
                found.append(
                    Finding(
                        rule: "B2", file: user.file, line: first.access.line,
                        what: "`\(user.shortName)` joins \(Array(Set(names)).sorted().joined(separator: " and "))"))
            }
        }
        // B4: a component naming a component it neither builds nor holds.
        for component in components {
            let own = children(of: component)
            for name in component.typeRefs.sorted() {
                guard let other = index.lookup(name, from: component), isComponent(other),
                    !index.isSelfOrNested(other, of: component), !own.contains(ObjectIdentifier(other)),
                    !component.inherits.contains(where: { index.lookup($0, from: component) === other })
                else { continue }
                found.append(
                    Finding(
                        rule: "B4", file: component.file, line: component.line,
                        what: "`\(component.shortName)` names `\(other.shortName)`, which it neither builds nor holds"))
            }
        }
        return found.sorted { ($0.rule, $0.file, $0.line) < ($1.rule, $1.file, $1.line) }
    }

    // MARK: Report

    func render(header: String) -> String {
        let all = findings()
        var out = header + "\n\n"
        out += "How to read: each finding breaks one rule of `macos/CLAUDE.md` § Component boundaries. "
        out += "Fix it the way its rule says; keep one only when the dependency can't be removed, and say why "
        out += "in the code. \(all.count) findings.\n"
        for rule in ["B1", "B2", "B3", "B4"] {
            let hits = all.filter { $0.rule == rule }
            guard let text = Self.rules[rule] else { continue }
            out += "\n## \(rule) — \(text.title) (\(hits.count))\n\n"
            out += "Fix: \(text.fix)\nRule: `macos/CLAUDE.md` § Component boundaries, \(rule).\n\n"
            for hit in hits { out += "- `\(hit.file):\(hit.line)` — \(hit.what)\n" }
            if hits.isEmpty { out += "- none\n" }
        }
        return out
    }
}
