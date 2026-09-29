import SwiftSyntax

/// `DETAIL=members`: inside each type, how its members use one another and
/// its state — the view a simplification pass reads. Per member: its size,
/// its branches, the members of its own type it calls, the members of other
/// mapped types it calls, the state it writes, and who calls it. Per class:
/// every stored `var` with its writers (its own members, and other types
/// writing it from outside), the flags among them (Bool, Optional, enum), and
/// the private members nothing calls or only one member calls.
///
/// Names are resolved syntactically. A parameter or local named like a
/// property is not the property, and an overload is told apart by its
/// argument labels. Framework members (AppKit, the standard library) are left
/// out; only mapped types appear.
struct MemberMap {
    let index: Index

    /// One function, initializer, subscript or computed property.
    final class Member {
        let owner: String
        let name: String
        let params: [(label: String, hasDefault: Bool)]
        let signature: String
        let access: String
        let lines: Int
        /// An override or `@objc`: called from outside the map.
        let exempt: Bool
        var branches = 0
        var sites: [Site] = []
        var writes: Set<String> = []
        var reads: Set<String> = []
        var calls: [String] = []
        var callers: Set<String> = []

        init(
            owner: String, name: String, params: [(label: String, hasDefault: Bool)], signature: String, access: String,
            lines: Int, exempt: Bool
        ) {
            self.owner = owner
            self.name = name
            self.params = params
            self.signature = signature
            self.access = access
            self.lines = lines
            self.exempt = exempt
        }

        var isPrivate: Bool { access == "private" || access == "fileprivate" }

        /// Whether a call with these labels (nil: a bare reference) can land
        /// here, defaulted parameters skipped, trailing closures matching any.
        func accepts(_ labels: [String]?) -> Bool {
            guard let labels else { return true }
            func match(_ param: Int, _ label: Int) -> Bool {
                guard label < labels.count else { return params[param...].allSatisfy(\.hasDefault) }
                guard param < params.count else { return false }
                let fits = labels[label] == "*" || params[param].label == labels[label]
                return (fits && match(param + 1, label + 1)) || (params[param].hasDefault && match(param + 1, label))
            }
            return match(0, 0)
        }
    }

    /// A use of a member: `type` nil for the walker's own type.
    struct Site {
        let type: String?
        let name: String
        let labels: [String]?
    }

    /// A write to another type's stored property: `type.name`.
    struct ForeignWrite: Hashable {
        let type: String
        let name: String
        let writer: String
    }

    /// Per mapped type (extensions merged): its members in source order.
    private(set) var members: [String: [Member]] = [:]
    private var foreignWrites: [ForeignWrite] = []

    init(index: Index, files: [SourceFile]) {
        self.index = index
        for file in files {
            let walker = MemberWalker(file: file, index: index)
            walker.walk(file.tree)
            for member in walker.found { members[member.owner, default: []].append(member) }
            foreignWrites += walker.foreignWrites
        }
        link()
    }

    /// Resolves every site to the members it can land on: an own member, the
    /// named type's, or — for a protocol — every mapped conformer's too.
    private func link() {
        var conformers: [String: [String]] = [:]
        for type in index.types where type.kind != "file" {
            for parent in type.inherits { conformers[parent, default: []].append(type.name) }
        }
        for (typeName, list) in members {
            for member in list {
                var shown: [String] = []
                for site in member.sites {
                    let home = site.type ?? typeName
                    var hit: Member?
                    for target in [home] + (conformers[home] ?? []) {
                        for callee in members[target] ?? []
                        where callee.name == site.name && callee.accepts(site.labels) {
                            callee.callers.insert(
                                site.type == nil ? member.name : "\(shortName(member.owner)).\(member.name)")
                            if target == home { hit = callee }
                        }
                    }
                    guard let hit else { continue }
                    let overloaded = (members[home] ?? []).filter { $0.name == hit.name }.count > 1
                    let label = overloaded ? hit.signature : hit.name
                    shown.append(site.type == nil ? label : "\(shortName(home)).\(label)")
                }
                member.calls = Array(Set(shown)).sorted()
            }
        }
    }

    private func shortName(_ name: String) -> String { String(name.split(separator: ".").last ?? Substring(name)) }

    // MARK: Render

    func render(unit: String, header: String) -> String {
        var out = [header, "", Self.legend]
        let types = index.types.filter { $0.unit == unit && $0.kind != "file" && $0.kind != "extension" }
            .sorted { ($0.file, $0.line) < ($1.file, $1.line) }
        for type in types {
            let list = members[type.name] ?? []
            // State with identity: a value type's fields are its callers' state.
            let state =
                ["class", "actor"].contains(type.kind)
                ? type.properties.filter { !$0.isLet && !$0.isStatic && !$0.isComputed } : []
            guard !list.isEmpty || !state.isEmpty else { continue }
            out += ["", "## \(type.name) (\(type.kind), \(type.lines)L)"]
            if !state.isEmpty { out.append("state:") }
            for property in state {
                var writers = list.filter { $0.writes.contains(property.name) }.map(\.name)
                writers += Set(foreignWrites.filter { $0.type == type.name && $0.name == property.name }.map(\.writer))
                    .sorted()
                let readers = list.filter { $0.reads.contains(property.name) }.count
                let flag = isFlag(property, in: type) ? " ⚑" : ""
                out.append(
                    "  \(property.name): \(describe(property, in: type))\(flag) — w: \(writers.isEmpty ? "init only" : writers.joined(separator: ", ")) · r: \(readers)"
                )
            }
            if !list.isEmpty { out.append("members:") }
            for member in list {
                var parts = ["  \(member.access) \(member.signature) \(member.lines)L"]
                if member.branches > 0 { parts.append("◇\(member.branches)") }
                if !member.calls.isEmpty { parts.append("→ " + member.calls.joined(separator: ", ")) }
                if !member.writes.isEmpty { parts.append("· w: " + member.writes.sorted().joined(separator: ", ")) }
                if !member.callers.isEmpty { parts.append("· ← " + member.callers.sorted().joined(separator: ", ")) }
                out.append(parts.joined(separator: " "))
            }
            let privates = list.filter { $0.isPrivate && !$0.exempt && $0.name != "init" }
            let uncalled = privates.filter { $0.callers.isEmpty }
            let single = privates.filter { $0.callers.count == 1 }
            if !uncalled.isEmpty {
                out.append("uncalled private: " + uncalled.map(\.signature).joined(separator: ", "))
            }
            if !single.isEmpty {
                out.append(
                    "one caller: "
                        + single.map { "\($0.signature) \($0.lines)L ← \($0.callers.first!)" }.joined(separator: ", "))
            }
            let unread = state.filter { property in
                property.isPrivate && !list.contains { $0.reads.contains(property.name) }
            }
            if !unread.isEmpty { out.append("never read: " + unread.map(\.name).joined(separator: ", ")) }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private func describe(_ property: Property, in type: TypeInfo) -> String {
        if let declared = property.type { return declared }
        if let resolved = index.propertyType(property, in: type) { return resolved.shortName }
        guard let value = property.initializer else { return "?" }
        if value.is(BooleanLiteralExprSyntax.self) { return "Bool" }
        let text = value.trimmedDescription
        return "= " + (text.count > 30 ? String(text.prefix(30)) + "…" : text)
    }

    private func isFlag(_ property: Property, in type: TypeInfo) -> Bool {
        let literal = property.initializer.flatMap { $0.is(BooleanLiteralExprSyntax.self) ? "Bool" : nil }
        guard let declared = property.type ?? literal else { return false }
        if declared == "Bool" || declared.hasSuffix("?") { return true }
        return index.coreName(declared).flatMap { index.lookup($0, from: type) }?.kind == "enum"
    }

    static let legend = """
        How to read: per class, `state` is every stored `var` with the members that write it (`w`; `Type.member` \
        for a write from outside) and how many of its own members read it (`r`); ⚑ marks a flag (Bool, Optional, \
        enum). Each member line is `access name(labels:) lines ◇branches → members it calls (`Type.member` for \
        another mapped type's) · w: state it writes · ← its callers`. Branches count `if`, `guard`, `case`, `?:`, \
        `??`, `&&`, `||`, `while` and `catch`. A call through a protocol counts for its conformers. `uncalled \
        private` and `one caller` are candidates to delete or inline (overrides and `@objc` members, called from \
        outside the map, are never listed); `never read` lists private state nothing reads. Resolution is \
        syntactic: framework members are left out, and a receiver the map can't type is dropped.
        """
}

/// Walks one file and fills a `MemberMap.Member` per function, initializer,
/// subscript and computed property of every type, with lexical scopes so a
/// local or parameter shadows a property of the same name.
private final class MemberWalker: SyntaxVisitor {
    private let index: Index
    private let converter: SourceLocationConverter
    private(set) var found: [MemberMap.Member] = []
    private(set) var foreignWrites: [MemberMap.ForeignWrite] = []

    /// The type being walked, its own member names, and its stored properties.
    private struct Owner {
        let name: String
        let info: TypeInfo?
        let memberNames: Set<String>
        let properties: [String: Property]
    }
    private var owners: [Owner] = []
    private var current: MemberMap.Member?
    /// Where `current` began, so only its own end closes it.
    private var currentNode: SyntaxIdentifier?
    /// Lexical scopes inside the current member: name → declared type, if known.
    private var scopes: [[String: String?]] = []

    init(file: SourceFile, index: Index) {
        self.index = index
        self.converter = SourceLocationConverter(fileName: file.path, tree: file.tree)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Types

    private func push(_ node: some DeclGroupSyntax, name: String, qualify: Bool) {
        let qualified = qualify ? (owners.last.map { $0.name + "." } ?? "") + name : name
        let info =
            index.types.first { $0.name == qualified && $0.kind != "extension" } ?? index.lookup(qualified, from: nil)
        var memberNames = Set((info?.members ?? []).map(\.name) + (info?.properties ?? []).map(\.name))
        for item in node.memberBlock.members {
            if let function = item.decl.as(FunctionDeclSyntax.self) { memberNames.insert(function.name.text) }
            if let variable = item.decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    if let id = binding.pattern.as(IdentifierPatternSyntax.self) {
                        memberNames.insert(id.identifier.text)
                    }
                }
            }
        }
        var properties: [String: Property] = [:]
        for property in info?.properties ?? [] where !property.isComputed { properties[property.name] = property }
        owners.append(
            Owner(name: info?.name ?? qualified, info: info, memberNames: memberNames, properties: properties))
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node, name: node.name.text, qualify: true)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { owners.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node, name: node.name.text, qualify: true)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { owners.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node, name: node.name.text, qualify: true)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { owners.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node, name: node.name.text, qualify: true)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { owners.removeLast() }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node, name: node.name.text, qualify: true)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { owners.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node, name: node.extendedType.trimmedDescription, qualify: false)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { owners.removeLast() }

    // MARK: Members

    private func begin(
        _ node: some SyntaxProtocol, name: String, modifiers: DeclModifierListSyntax, attributes: AttributeListSyntax,
        params: FunctionParameterClauseSyntax?
    ) -> SyntaxVisitorContinueKind {
        guard let owner = owners.last else { return .skipChildren }
        if attributes.contains(where: { $0.trimmedDescription.contains("unavailable") }) { return .skipChildren }
        let declared =
            ["open", "public", "package", "internal", "fileprivate", "private"].first { level in
                modifiers.contains { $0.name.text == level }
            }
        // A protocol's requirements have the protocol's access.
        let access = declared ?? (owner.info?.kind == "protocol" ? owner.info?.access : nil) ?? "internal"
        let list = params?.parameters.map { (label: $0.firstName.text, hasDefault: $0.defaultValue != nil) } ?? []
        let signature = params == nil ? name : "\(name)(\(list.map { "\($0.label):" }.joined()))"
        let lines = node.endLocation(converter: converter).line - node.startLocation(converter: converter).line + 1
        current = MemberMap.Member(
            owner: owner.name, name: name, params: list, signature: signature, access: access, lines: lines,
            exempt: modifiers.contains { $0.name.text == "override" }
                || attributes.contains { $0.trimmedDescription.hasPrefix("@objc") })
        currentNode = node.id
        scopes = [[:]]
        for param in params?.parameters ?? [] {
            scopes[0][(param.secondName ?? param.firstName).text] = param.type.trimmedDescription
        }
        return .visitChildren
    }

    private func end(_ node: some SyntaxProtocol) {
        guard let member = current, currentNode == node.id else { return }
        found.append(member)
        current = nil
        currentNode = nil
        scopes = []
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard current != nil else {
            return begin(
                node, name: node.name.text, modifiers: node.modifiers, attributes: node.attributes,
                params: node.signature.parameterClause)
        }
        pushScope()  // a nested function: its parameters are locals
        for param in node.signature.parameterClause.parameters {
            bind((param.secondName ?? param.firstName).text, type: param.type.trimmedDescription)
        }
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        if currentNode == node.id { end(node) } else { popScope() }
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        guard current == nil else { return .visitChildren }
        return begin(
            node, name: "init", modifiers: node.modifiers, attributes: node.attributes,
            params: node.signature.parameterClause)
    }
    override func visitPost(_ node: InitializerDeclSyntax) { end(node) }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        guard current == nil else { return .visitChildren }
        return begin(
            node, name: "subscript", modifiers: node.modifiers, attributes: node.attributes,
            params: node.parameterClause)
    }
    override func visitPost(_ node: SubscriptDeclSyntax) { end(node) }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard current == nil else { return .visitChildren }
        // A computed property, or one with observers, is a member with a body;
        // a stored property's initializer is nobody's.
        guard let binding = node.bindings.first, binding.accessorBlock != nil,
            let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        else { return .skipChildren }
        return begin(node, name: name, modifiers: node.modifiers, attributes: node.attributes, params: nil)
    }
    override func visitPost(_ node: VariableDeclSyntax) { end(node) }

    // MARK: Scopes

    private func pushScope() { if current != nil { scopes.append([:]) } }
    private func popScope() { if current != nil, scopes.count > 1 { scopes.removeLast() } }
    private func bind(_ name: String, type: String?) {
        guard current != nil, !scopes.isEmpty else { return }
        scopes[scopes.count - 1][name] = .some(type)
    }
    /// nil when the name isn't local; else the local's declared type, if any.
    private func local(_ name: String) -> String?? {
        for scope in scopes.reversed() { if let hit = scope[name] { return .some(hit) } }
        return nil
    }

    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        pushScope()
        return .visitChildren
    }
    override func visitPost(_ node: CodeBlockSyntax) { popScope() }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        pushScope()
        if let parameters = node.signature?.parameterClause {
            switch parameters {
            case .simpleInput(let list):
                for param in list { bind(param.name.text, type: nil) }
            case .parameterClause(let clause):
                for param in clause.parameters {
                    bind((param.secondName ?? param.firstName).text, type: param.type?.trimmedDescription)
                }
            }
        }
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { popScope() }
    /// `if let` and `while let` bind for their own bodies only; `guard let`
    /// binds for the rest of the enclosing block.
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        current?.branches += 1
        pushScope()
        return .visitChildren
    }
    override func visitPost(_ node: IfExprSyntax) { popScope() }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        current?.branches += 1
        pushScope()
        return .visitChildren
    }
    override func visitPost(_ node: WhileStmtSyntax) { popScope() }
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        pushScope()
        return .visitChildren
    }
    override func visitPost(_ node: ForStmtSyntax) { popScope() }
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        current?.branches += 1
        pushScope()
        return .visitChildren
    }
    override func visitPost(_ node: SwitchCaseSyntax) { popScope() }
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        current?.branches += 1
        pushScope()
        bind("error", type: nil)
        return .visitChildren
    }
    override func visitPost(_ node: CatchClauseSyntax) { popScope() }

    /// Bound after its initializer is walked: `let x = x` reads the outer `x`.
    override func visitPost(_ node: PatternBindingSyntax) {
        guard current != nil, let id = node.pattern.as(IdentifierPatternSyntax.self) else { return }
        bind(
            id.identifier.text,
            type: node.typeAnnotation?.type.trimmedDescription ?? node.initializer.flatMap { inferred($0.value) })
    }
    override func visitPost(_ node: IdentifierPatternSyntax) {
        // Every other binding site: `case let`, `for x in`, tuples.
        if node.parent?.is(PatternBindingSyntax.self) == true
            || node.parent?.is(OptionalBindingConditionSyntax.self) == true
        {
            return
        }
        bind(node.identifier.text, type: nil)
    }
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        // `if let x` reads `x` before it binds it.
        if node.initializer == nil, let id = node.pattern.as(IdentifierPatternSyntax.self),
            local(id.identifier.text) == nil
        {
            touch(id.identifier.text, labels: nil, write: false)
        }
        return .visitChildren
    }
    /// `if let x = e` / `guard let x`: `x` has `e`'s type, unwrapped.
    override func visitPost(_ node: OptionalBindingConditionSyntax) {
        guard let id = node.pattern.as(IdentifierPatternSyntax.self) else { return }
        let source = node.initializer?.value ?? ExprSyntax(DeclReferenceExprSyntax(baseName: id.identifier))
        bind(id.identifier.text, type: node.typeAnnotation?.type.trimmedDescription ?? inferred(source))
    }

    /// The mapped type an initializer produces, when the map can tell.
    private func inferred(_ value: ExprSyntax) -> String? {
        let value = stripped(value)
        if let call = value.as(FunctionCallExprSyntax.self),
            let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
            ref.baseName.text.first?.isUppercase == true
        {
            return ref.baseName.text
        }
        return typeOf(value)?.name
    }

    // MARK: Branches

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        current?.branches += 1
        return .visitChildren
    }
    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        current?.branches += 1
        return .visitChildren
    }
    override func visit(_ node: UnresolvedTernaryExprSyntax) -> SyntaxVisitorContinueKind {
        current?.branches += 1
        return .visitChildren
    }
    override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if ["&&", "||", "??"].contains(node.operator.text) { current?.branches += 1 }
        return .visitChildren
    }

    // MARK: References

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard current != nil else { return .visitChildren }
        if let access = node.parent?.as(MemberAccessExprSyntax.self), access.declName.id == node.id {
            return .visitChildren  // the member half of `a.b`: handled with its base
        }
        let name = node.baseName.text
        guard local(name) == nil else { return .visitChildren }
        let expr = ExprSyntax(node)
        touch(name, labels: callLabels(expr), write: isWritten(expr))
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard current != nil, let owner = owners.last, let rawBase = node.base else { return .visitChildren }
        let base = stripped(rawBase)
        let name = node.declName.baseName.text
        let expr = ExprSyntax(node)
        let text = base.trimmedDescription
        if text == "self" || text == "Self" || text == owner.name.split(separator: ".").last.map(String.init) {
            touch(name, labels: callLabels(expr), write: isWritten(expr))
            return .visitChildren
        }
        guard let type = typeOf(base) else { return .visitChildren }
        if let labels = callLabels(expr), type.name != owner.name {
            current?.sites.append(MemberMap.Site(type: type.name, name: name, labels: labels))
        } else if isWritten(expr, direct: true), type.properties.contains(where: { $0.name == name }) {
            foreignWrites.append(
                MemberMap.ForeignWrite(
                    type: type.name, name: name,
                    writer: "\(owner.name.split(separator: ".").last ?? "").\(current?.name ?? "")"))
        }
        return .visitChildren
    }

    private func touch(_ name: String, labels: [String]?, write: Bool) {
        guard let owner = owners.last, let member = current, owner.memberNames.contains(name) else { return }
        if owner.properties[name] != nil {
            if write { member.writes.insert(name) }
            if !write || !isPlainAssignmentTarget { member.reads.insert(name) }
        } else {
            member.sites.append(MemberMap.Site(type: nil, name: name, labels: labels))
        }
    }

    /// Set by `isWritten` for its last answer: `x = …` writes without reading.
    private var isPlainAssignmentTarget = false

    /// The type of a receiver: a stored property (`x`, `self.x`), a parameter
    /// or local with a declared type, or a type name.
    private func typeOf(_ base: ExprSyntax) -> TypeInfo? {
        var name: String?
        if let ref = base.as(DeclReferenceExprSyntax.self) {
            name = ref.baseName.text
        } else if let access = base.as(MemberAccessExprSyntax.self), access.base?.trimmedDescription == "self" {
            name = access.declName.baseName.text
        }
        guard let name, let owner = owners.last else { return nil }
        if base.is(DeclReferenceExprSyntax.self), let hit = local(name) {
            return hit.flatMap(index.coreName).flatMap { index.lookup($0, from: owner.info) }
        }
        if let property = owner.properties[name], let info = owner.info {
            return index.propertyType(property, in: info)
        }
        if name.first?.isUppercase == true { return index.lookup(name, from: owner.info) }
        return nil
    }

    private func stripped(_ expr: ExprSyntax) -> ExprSyntax {
        if let e = expr.as(OptionalChainingExprSyntax.self) { return stripped(e.expression) }
        if let e = expr.as(ForceUnwrapExprSyntax.self) { return stripped(e.expression) }
        return expr
    }

    /// The argument labels when `expr` is called (`_` unlabeled, `*` a
    /// trailing closure); nil when it is only referenced.
    private func callLabels(_ expr: ExprSyntax) -> [String]? {
        var node = Syntax(expr)
        while let parent = node.parent,
            parent.is(OptionalChainingExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self)
        {
            node = parent
        }
        guard let call = node.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == node.id else {
            return nil
        }
        let trailing = (call.trailingClosure == nil ? 0 : 1) + call.additionalTrailingClosures.count
        return call.arguments.map { $0.label?.text ?? "_" } + Array(repeating: "*", count: trailing)
    }

    private static let mutating: Set<String> = [
        "append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "removeValue", "removeSubrange",
        "updateValue", "formUnion", "formIntersection", "subtract", "sort", "reverse", "popLast", "merge", "toggle",
        "replaceSubrange",
    ]

    /// Written: the target of an assignment or `inout`, directly or — unless
    /// `direct` — through a value's member (`x.y = …`, `x[i] = …`,
    /// `x.append(…)`).
    private func isWritten(_ expr: ExprSyntax, direct: Bool = false) -> Bool {
        isPlainAssignmentTarget = false
        var node = Syntax(expr)
        while let parent = node.parent {
            if let access = parent.as(MemberAccessExprSyntax.self), access.base?.id == node.id, !direct {
                if let call = access.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == access.id,
                    Self.mutating.contains(access.declName.baseName.text)
                {
                    return true
                }
                node = parent
            } else if let element = parent.as(SubscriptCallExprSyntax.self), element.calledExpression.id == node.id,
                !direct
            {
                node = parent
            } else if parent.is(OptionalChainingExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self) {
                node = parent
            } else {
                break
            }
        }
        if node.parent?.is(InOutExprSyntax.self) == true { return true }
        guard let list = node.parent?.as(ExprListSyntax.self) else { return false }
        let elements = Array(list)
        guard let position = elements.firstIndex(where: { $0.id == node.id }), position + 1 < elements.count else {
            return false
        }
        let next = elements[position + 1]
        if next.is(AssignmentExprSyntax.self) {
            isPlainAssignmentTarget = node.id == Syntax(expr).id
            return true
        }
        if let op = next.as(BinaryOperatorExprSyntax.self)?.operator.text {
            return op.hasSuffix("=") && !["==", "!=", "<=", ">=", "===", "!=="].contains(op)
        }
        return false
    }
}
