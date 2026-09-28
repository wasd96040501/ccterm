import SwiftSyntax

/// Every type in the parsed universe, with names resolved across files:
/// dependencies between types, the source each data flow reads from, and which
/// members of a type other units actually touch.
final class Index {
    private(set) var types: [TypeInfo] = []
    private var byName: [String: [TypeInfo]] = [:]
    let modules: Set<String>

    /// Resolved type → types it names or constructs (self and nesting excluded).
    private(set) var deps: [ObjectIdentifier: [TypeInfo]] = [:]
    /// Type → other unit → members of the type that unit touches ("init" for construction).
    private(set) var usedBy: [ObjectIdentifier: [String: Set<String>]] = [:]
    /// Type → the types that name or construct it.
    private(set) var referencedBy: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
    /// Type → units that extend it from outside its own unit.
    private(set) var extendedIn: [ObjectIdentifier: Set<String>] = [:]
    /// Member names touched through an unresolved receiver, per module — the
    /// conservative fallback when deciding a public member is unused.
    private var unresolvedAccesses: [String: Set<String>] = [:]
    private var resolvedUses: [ObjectIdentifier: [String: Set<String>]] = [:]  // type → member → modules

    init(files: [SourceFile]) {
        modules = Set(files.map(\.module))
        var extensions: [TypeInfo] = []
        for file in files {
            let extractor = Extractor(file: file)
            extractor.run()
            types += extractor.types
            extensions += extractor.extensions
        }
        for info in types where info.kind != "file" { byName[info.name, default: []].append(info) }
        mergeExtensions(extensions)
        resolve()
    }

    // MARK: Lookup

    func lookup(_ rawName: String, from owner: TypeInfo?) -> TypeInfo? {
        var name = rawName
        if let generic = name.firstIndex(of: "<") { name = String(name[..<generic]) }
        if let first = name.split(separator: ".").first, modules.contains(String(first)), name.contains(".") {
            name = String(name.dropFirst(first.count + 1))
        }
        if let owner, owner.kind != "file", owner.kind != "extension" {
            var prefix = owner.name.split(separator: ".").map(String.init)
            while !prefix.isEmpty {
                if let hit = byName[(prefix + [name]).joined(separator: ".")]?.first(where: {
                    $0.module == owner.module
                }) {
                    return hit
                }
                prefix.removeLast()
            }
        }
        let visible = (byName[name] ?? []).filter { owner?.visibleModules.contains($0.module) ?? true }
        return visible.first { $0.module == owner?.module } ?? visible.first
    }

    /// `LibraryStore?`, `any SessionDelegate`, `Optional<Foo>` → the named type; nil for
    /// collections, closures, tuples — a member access on those isn't the element's.
    func coreName(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["any ", "some ", "inout ", "@escaping ", "@MainActor ", "@Sendable "] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        while t.hasSuffix("?") || t.hasSuffix("!") { t.removeLast() }
        if t.hasPrefix("Optional<"), t.hasSuffix(">") { t = String(t.dropFirst(9).dropLast()) }
        if t.hasPrefix("("), t.hasSuffix(")"), !t.contains("->"), !t.contains(",") {
            t = String(t.dropFirst().dropLast())
        }
        let base = t.split(separator: "<").first.map(String.init) ?? t
        guard base.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }), !base.isEmpty else {
            return nil
        }
        return base
    }

    func propertyType(_ property: Property, in owner: TypeInfo) -> TypeInfo? {
        if let type = property.type { return coreName(type).flatMap { lookup($0, from: owner) } }
        if let value = property.initializer { return typeOf(value, scope: nil, owner: owner) }
        return nil
    }

    private func findProperty(_ name: String, in type: TypeInfo) -> Property? {
        if let hit = type.properties.first(where: { $0.name == name }) { return hit }
        // Inherited from a supertype we also map (protocol requirement or base class).
        for parent in type.inherits {
            if let parentType = lookup(parent, from: type), parentType !== type,
                let hit = parentType.properties.first(where: { $0.name == name })
            {
                return hit
            }
        }
        return nil
    }

    // MARK: Expression typing

    private func unwrap(_ expr: ExprSyntax) -> ExprSyntax {
        if let e = expr.as(OptionalChainingExprSyntax.self) { return unwrap(e.expression) }
        if let e = expr.as(ForceUnwrapExprSyntax.self) { return unwrap(e.expression) }
        if let e = expr.as(TryExprSyntax.self) { return unwrap(e.expression) }
        if let e = expr.as(AwaitExprSyntax.self) { return unwrap(e.expression) }
        if let e = expr.as(TupleExprSyntax.self), e.elements.count == 1, let only = e.elements.first {
            return unwrap(only.expression)
        }
        return expr
    }

    /// The mapped type an expression evaluates to (a metatype counts as its type), if knowable.
    func typeOf(_ raw: ExprSyntax, scope: Scope?, owner: TypeInfo, depth: Int = 0) -> TypeInfo? {
        guard depth < 6 else { return nil }
        let expr = unwrap(raw)
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if name == "self" || name == "Self" { return owner.kind == "file" ? nil : owner }
            switch scope?.lookup(name) {
            case .type(let t): return coreName(t).flatMap { lookup($0, from: owner) }
            case .expr(let e): return typeOf(e, scope: scope, owner: owner, depth: depth + 1)
            case nil: break
            }
            if let property = findProperty(name, in: owner) { return propertyType(property, in: owner) }
            if name.first?.isUppercase == true { return lookup(name, from: owner) }
            return nil
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            guard let baseType = typeOf(base, scope: scope, owner: owner, depth: depth + 1) else {
                // `Module.Type` or a dotted nested name.
                return lookup(member.trimmedDescription, from: owner)
            }
            let name = member.declName.baseName.text
            if let property = findProperty(name, in: baseType) { return propertyType(property, in: baseType) }
            return byName[baseType.name + "." + name]?.first
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            let callee = unwrap(call.calledExpression)
            if let ref = callee.as(DeclReferenceExprSyntax.self) {
                let name = ref.baseName.text
                if name.first?.isUppercase == true { return lookup(name, from: owner) }
                return returnType(of: name, in: owner)
            }
            if let generic = callee.as(GenericSpecializationExprSyntax.self) {
                return typeOf(generic.expression, scope: scope, owner: owner, depth: depth + 1)
            }
            if let member = callee.as(MemberAccessExprSyntax.self), let base = member.base,
                let baseType = typeOf(base, scope: scope, owner: owner, depth: depth + 1)
            {
                let name = member.declName.baseName.text
                return name == "init" ? baseType : returnType(of: name, in: baseType)
            }
        }
        if let cast = expr.as(AsExprSyntax.self) {
            return coreName(cast.type.trimmedDescription).flatMap { lookup($0, from: owner) }
        }
        return nil
    }

    private func returnType(of function: String, in type: TypeInfo) -> TypeInfo? {
        guard let member = type.members.first(where: { $0.name == function }), let result = member.returnType else {
            return nil
        }
        if result == "Self" { return type }
        return coreName(result).flatMap { lookup($0, from: type) }
    }

    /// Renders a flow subject with its receiver resolved: `store.$nodes` →
    /// `LibraryStore.$nodes`; also returns the mapped type the flow comes from.
    func describe(_ raw: ExprSyntax, scope: Scope?, owner: TypeInfo, depth: Int = 0) -> (String, TypeInfo?)? {
        guard depth < 6 else { return nil }
        let expr = unwrap(raw)
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            let name = member.declName.baseName.text
            if let type = typeOf(base, scope: scope, owner: owner) { return ("\(type.name).\(name)", type) }
            guard let (text, type) = describe(base, scope: scope, owner: owner, depth: depth + 1) else { return nil }
            return ("\(text).\(name)", type)
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            guard let (text, type) = describe(call.calledExpression, scope: scope, owner: owner, depth: depth + 1)
            else {
                return nil
            }
            return (text + (call.arguments.isEmpty ? "()" : "(…)"), type)
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if name == "self" { return (owner.name, owner) }
            switch scope?.lookup(name) {
            case .expr(let e): return describe(e, scope: scope, owner: owner, depth: depth + 1)
            case .type(let t): return ("\(name): \(t)", coreName(t).flatMap { lookup($0, from: owner) })
            case nil: break
            }
            if findProperty(name, in: owner) != nil { return ("\(owner.name).\(name)", owner) }
            if name.first?.isUppercase == true { return (name, lookup(name, from: owner)) }
            return nil  // a closure parameter (a TaskGroup, say): local, not a flow between types
        }
        let text = expr.trimmedDescription.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: " ")
        return (text.count > 60 ? String(text.prefix(57)) + "…" : text, nil)
    }

    // MARK: Resolution passes

    private func mergeExtensions(_ extensions: [TypeInfo]) {
        var foreign: [String: TypeInfo] = [:]
        for ext in extensions {
            if let target = lookup(ext.name, from: ext) {
                target.inherits += ext.inherits.filter { !target.inherits.contains($0) }
                target.properties += ext.properties
                target.members += ext.members
                target.inits += ext.inits
                target.initParams.formUnion(ext.initParams)
                target.typeRefs.formUnion(ext.typeRefs)
                target.creates += ext.creates
                target.hosts += ext.hosts
                target.flows += ext.flows
                target.accesses += ext.accesses
                target.tasks += ext.tasks
                target.nested += ext.nested
                target.extensionLines += ext.lines
                if ext.unit != target.unit { extendedIn[ObjectIdentifier(target), default: []].insert(ext.unit) }
            } else if let merged = foreign[ext.unit + "|" + ext.name] {
                merged.properties += ext.properties
                merged.members += ext.members
                merged.inherits += ext.inherits.filter { !merged.inherits.contains($0) }
                merged.typeRefs.formUnion(ext.typeRefs)
                merged.creates += ext.creates
                merged.flows += ext.flows
                merged.accesses += ext.accesses
                merged.tasks += ext.tasks
                merged.extensionLines += ext.lines
            } else {
                foreign[ext.unit + "|" + ext.name] = ext
                types.append(ext)
            }
        }
    }

    private func resolve() {
        for type in types {
            let id = ObjectIdentifier(type)
            var found: [ObjectIdentifier: TypeInfo] = [:]
            for name in type.typeRefs {
                guard let target = lookup(name, from: type), !isSelfOrNested(target, of: type) else { continue }
                found[ObjectIdentifier(target)] = target
                recordUse(of: nil, on: target, from: type)
            }
            for name in type.creates {
                guard let target = lookup(name, from: type), !isSelfOrNested(target, of: type) else { continue }
                found[ObjectIdentifier(target)] = target
                recordUse(of: "init", on: target, from: type)
            }
            deps[id] = found.values.sorted { $0.name < $1.name }
            for target in found.keys { referencedBy[target, default: []].insert(id) }

            for access in type.accesses {
                guard let target = typeOf(access.base, scope: access.scope, owner: type) else {
                    unresolvedAccesses[type.module, default: []].insert(access.name)
                    continue
                }
                guard !isSelfOrNested(target, of: type), access.name != "self" else { continue }
                let name = access.name.hasPrefix("$") ? String(access.name.dropFirst()) : access.name
                // Only the target's own API counts as its surface; inherited
                // framework members (`view`, `addSubview`) aren't.
                let declared =
                    target.members.contains { $0.name == name } || target.properties.contains { $0.name == name }
                    || target.nested.contains(name)
                recordUse(of: declared ? name : nil, on: target, from: type)
            }
        }
    }

    /// Notes that `user` touches `target` (a member of it, or just its name).
    private func recordUse(of member: String?, on target: TypeInfo, from user: TypeInfo) {
        let id = ObjectIdentifier(target)
        if let member { resolvedUses[id, default: [:]][member, default: []].insert(user.module) }
        guard target.unit != user.unit else { return }
        var members = usedBy[id, default: [:]][user.unit, default: []]
        if let member { members.insert(member) }
        usedBy[id, default: [:]][user.unit] = members
    }

    func isSelfOrNested(_ a: TypeInfo, of b: TypeInfo) -> Bool {
        a === b || a.name.hasPrefix(b.name + ".") || b.name.hasPrefix(a.name + ".")
    }

    // MARK: Queries for rendering

    /// `public` / `open` members of a package type that nothing outside its
    /// module touches — candidates for narrowing. Overrides and `@objc`
    /// witnesses are excluded; so is any name some other module reaches
    /// through a receiver the map couldn't type.
    func unusedPublicMembers(of type: TypeInfo) -> [String] {
        // Value types' public fields are their data contract; behaviour is what leaks.
        guard ["public", "open"].contains(type.access), type.kind == "class" || type.kind == "actor" else { return [] }
        let uses = resolvedUses[ObjectIdentifier(type)] ?? [:]
        let names =
            type.members.filter { ["public", "open"].contains($0.access) && !$0.isOverride && !$0.isObjC }.map(\.name)
            + type.properties.filter { !$0.isLet && ($0.modifiers.contains("public") || $0.modifiers.contains("open")) }
            .map(\.name)
        return Set(names).filter { name in
            let outside = (uses[name] ?? []).contains { $0 != type.module }
            let maybe = unresolvedAccesses.contains { $0.key != type.module && $0.value.contains(name) }
            return !outside && !maybe
        }.sorted()
    }

    /// Tarjan's SCCs of size > 1 over a graph given as node → successors.
    static func cycles<Node: Hashable>(_ nodes: [Node], edges: (Node) -> [Node]) -> [[Node]] {
        var index = 0
        var indices: [Node: Int] = [:]
        var low: [Node: Int] = [:]
        var stack: [Node] = []
        var onStack: Set<Node> = []
        var result: [[Node]] = []
        func connect(_ v: Node) {
            indices[v] = index
            low[v] = index
            index += 1
            stack.append(v)
            onStack.insert(v)
            for w in edges(v) {
                if indices[w] == nil {
                    connect(w)
                    low[v] = min(low[v]!, low[w]!)
                } else if onStack.contains(w) {
                    low[v] = min(low[v]!, indices[w]!)
                }
            }
            if low[v] == indices[v] {
                var component: [Node] = []
                while let w = stack.popLast() {
                    onStack.remove(w)
                    component.append(w)
                    if w == v { break }
                }
                if component.count > 1 { result.append(component) }
            }
        }
        for node in nodes where indices[node] == nil { connect(node) }
        return result
    }
}
