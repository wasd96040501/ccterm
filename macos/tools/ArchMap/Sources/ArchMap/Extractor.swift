import SwiftSyntax

/// Walks one file and records, per declared type, what the map reports:
/// declaration shape, stored state, the types it names, what it constructs,
/// and every data-flow construct (Combine sinks, `for await`, observation
/// tracking, notifications, callback / delegate wiring). Purely syntactic —
/// names are resolved later by `Index`, once every file has been read.
final class Extractor: SyntaxVisitor {
    private let file: SourceFile
    private let converter: SourceLocationConverter
    private(set) var types: [TypeInfo] = []
    /// `extension X` blocks, merged into `X` by `Index` when X is ours.
    private(set) var extensions: [TypeInfo] = []

    private var owners: [TypeInfo] = []
    private var fileLevel: TypeInfo?
    private var scope: Scope
    /// > 0 inside any body (function, accessor, closure): a `var` there is a
    /// local, not a property.
    private var bodyDepth = 0

    init(file: SourceFile) {
        self.file = file
        self.converter = SourceLocationConverter(fileName: file.path, tree: file.tree)
        self.scope = Scope(parent: nil)
        super.init(viewMode: .sourceAccurate)
    }

    func run() {
        walk(file.tree)
        if let fileLevel, !(fileLevel.flows.isEmpty && fileLevel.properties.isEmpty && fileLevel.members.isEmpty) {
            types.append(fileLevel)
        }
    }

    // MARK: Owners

    private var owner: TypeInfo {
        if let last = owners.last { return last }
        if let fileLevel { return fileLevel }
        let info = TypeInfo(name: "(file scope)", kind: "file", file: file, line: 1, endLine: file.lines)
        fileLevel = info
        return info
    }

    private func line(_ node: some SyntaxProtocol) -> Int {
        node.startLocation(converter: converter).line
    }

    private func endLine(_ node: some SyntaxProtocol) -> Int {
        node.endLocation(converter: converter).line
    }

    private func pushType(
        _ node: some DeclGroupSyntax, name: String, kind: String, inherits: InheritanceClauseSyntax?
    ) {
        let qualified = (owners.last.map { $0.name + "." } ?? "") + name
        let info = TypeInfo(name: qualified, kind: kind, file: file, line: line(node), endLine: endLine(node))
        info.modifiers = node.modifiers.map(\.name.text)
        info.attributes = node.attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }
            .map { "@" + $0 }
        info.inherits = inherits?.inheritedTypes.map(\.type.trimmedDescription) ?? []
        owners.last?.nested.append(name)
        if kind == "extension" { extensions.append(info) } else { types.append(info) }
        owners.append(info)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node, name: node.name.text, kind: "class", inherits: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { owners.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node, name: node.name.text, kind: "struct", inherits: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { owners.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node, name: node.name.text, kind: "enum", inherits: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { owners.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node, name: node.name.text, kind: "actor", inherits: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { owners.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node, name: node.name.text, kind: "protocol", inherits: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { owners.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // Extensions are declared at file scope; the extended name is resolved
        // against the whole map later, so don't qualify it by any owner.
        let saved = owners
        owners = []
        pushType(node, name: node.extendedType.trimmedDescription, kind: "extension", inherits: node.inheritanceClause)
        savedOwners.append(saved)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        owners = savedOwners.removeLast()
    }
    private var savedOwners: [[TypeInfo]] = []

    // MARK: Bodies and scopes

    private func enterBody(params: FunctionParameterClauseSyntax?) {
        bodyDepth += 1
        scope = Scope(parent: scope)
        for param in params?.parameters ?? [] {
            let name = (param.secondName ?? param.firstName).text
            scope.bindings[name] = .type(param.type.trimmedDescription)
        }
    }

    private func leaveBody() {
        bodyDepth -= 1
        scope = scope.parent ?? scope
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if bodyDepth == 0 {
            owner.members.append(
                Member(
                    name: node.name.text,
                    access: accessLevel(node.modifiers),
                    isOverride: node.modifiers.contains { $0.name.text == "override" },
                    isObjC: node.attributes.contains {
                        $0.trimmedDescription.hasPrefix("@objc") || $0.trimmedDescription.hasPrefix("@IBAction")
                    },
                    returnType: node.signature.returnClause?.type.trimmedDescription,
                    isWitness: owner.kind == "extension" && !owner.inherits.isEmpty,
                    isStatic: node.modifiers.contains { ["static", "class"].contains($0.name.text) }))
        }
        enterBody(params: node.signature.parameterClause)
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { leaveBody() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if bodyDepth == 0 {
            let access = accessLevel(node.modifiers)
            let unavailable = node.attributes.contains { $0.trimmedDescription.contains("unavailable") }
            if access != "private" && access != "fileprivate" && !unavailable {
                let params = node.signature.parameterClause.parameters.map { param in
                    "\(param.firstName.text): \(param.type.trimmedDescription)"
                }
                owner.inits.append("init(\(params.joined(separator: ", ")))")
            }
            for param in node.signature.parameterClause.parameters {
                owner.initParams.insert((param.secondName ?? param.firstName).text)
            }
            owner.members.append(
                Member(name: "init", access: access, isOverride: false, isObjC: false, returnType: nil))
        }
        enterBody(params: node.signature.parameterClause)
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) { leaveBody() }

    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        enterBody(params: nil)
        return .visitChildren
    }
    override func visitPost(_ node: AccessorBlockSyntax) { leaveBody() }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        enterBody(params: nil)
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { leaveBody() }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            if bodyDepth > 0 {
                if let type = binding.typeAnnotation?.type {
                    scope.bindings[name] = .type(type.trimmedDescription)
                } else if let value = binding.initializer?.value,
                    value.as(DeclReferenceExprSyntax.self)?.baseName.text != name
                {
                    // `let directory = directory` (a capture copy) binds nothing new:
                    // the name keeps resolving to the outer property or parameter.
                    scope.bindings[name] = .expr(value)
                }
                continue
            }
            let isComputed: Bool = {
                guard let accessors = binding.accessorBlock?.accessors else { return false }
                if case .accessors(let list) = accessors {
                    return list.contains { !["willSet", "didSet"].contains($0.accessorSpecifier.text) }
                }
                return true
            }()
            owner.properties.append(
                Property(
                    name: name,
                    type: binding.typeAnnotation?.type.trimmedDescription,
                    initializer: binding.initializer?.value,
                    isLet: node.bindingSpecifier.text == "let",
                    isStatic: node.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" },
                    isComputed: isComputed,
                    modifiers: node.modifiers.map(\.trimmedDescription),
                    wrappers: node.attributes.compactMap {
                        $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
                    }
                    .map { "@" + $0 }))
        }
        return .visitChildren
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
            let value = node.initializer?.value
        {
            scope.bindings[name] = .expr(value)
        }
        return .visitChildren
    }

    // MARK: References

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        owner.typeRefs.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // `UserMessage.Sender` names that nested type, not whatever `UserMessage`
        // resolves to on its own.
        owner.typeRefs.insert(node.trimmedDescription.replacingOccurrences(of: " ", with: ""))
        return .skipChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if name.first?.isUppercase == true { owner.typeRefs.insert(name) }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if let base = node.base, !["self", "Self", "super"].contains(base.trimmedDescription) {
            var statement: Syntax? = Syntax(node)
            while let current = statement, !current.is(CodeBlockItemSyntax.self),
                !current.is(MemberBlockItemSyntax.self)
            {
                statement = current.parent
            }
            owner.accesses.append(
                Access(
                    base: base, name: node.declName.baseName.text, scope: scope, line: line(node),
                    statement: statement?.id, file: file.path))
        }
        return .visitChildren
    }

    // MARK: Calls — construction and flow

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression
        recordPins(node)
        if let constructed = constructedType(callee) {
            if constructed == "Task" {
                owner.tasks += 1
            } else {
                owner.creates.append(constructed)
                for argument in node.arguments {
                    // `Render` keeps only the ones that turn out to be publishers or streams.
                    for root in publisherRoots(argument.expression) {
                        guard root.is(MemberAccessExprSyntax.self) || root.is(FunctionCallExprSyntax.self) else {
                            continue
                        }
                        owner.flows.append(
                            Flow(
                                kind: .passes, subject: root, scope: scope,
                                target: (constructed, argument.label?.text ?? "_")))
                    }
                }
            }
            if constructed.hasPrefix("NSHosting"),
                let root = node.arguments.first?.expression.as(FunctionCallExprSyntax.self),
                let hosted = constructedType(root.calledExpression)
            {
                owner.hosts.append(hosted)
            }
        }
        if let member = callee.as(MemberAccessExprSyntax.self) {
            recordFlow(call: node, member: member)
        }
        if callee.as(DeclReferenceExprSyntax.self)?.baseName.text == "withObservationTracking",
            let closure = node.arguments.first?.expression.as(ClosureExprSyntax.self) ?? node.trailingClosure
        {
            for read in maximalMemberChains(in: closure) {
                owner.flows.append(Flow(kind: .tracking, subject: read, scope: scope))
            }
        }
        return .visitChildren
    }

    private func recordFlow(call: FunctionCallExprSyntax, member: MemberAccessExprSyntax) {
        guard let base = member.base else { return }
        let name = member.declName.baseName.text
        let isCenter = base.trimmedDescription.contains("NotificationCenter")
        switch name {
        case "detached" where base.trimmedDescription == "Task":
            owner.tasks += 1
        case "sink", "assign":
            for root in publisherRoots(base) { owner.flows.append(Flow(kind: .sink, subject: root, scope: scope)) }
        case "post" where isCenter:
            owner.flows.append(Flow(kind: .notifyPost, subject: base, scope: scope, detail: argument(call, "name")))
        case "addObserver" where isCenter, "publisher" where isCenter, "notifications" where isCenter:
            let detail = argument(call, "name") ?? argument(call, "named") ?? argument(call, "for")
            owner.flows.append(Flow(kind: .notifyObserve, subject: base, scope: scope, detail: detail))
        case "observe":
            if let keyPath = call.arguments.first?.expression.as(KeyPathExprSyntax.self) {
                owner.flows.append(Flow(kind: .kvo, subject: base, scope: scope, detail: keyPath.trimmedDescription))
            }
        default:
            break
        }
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        if node.awaitKeyword != nil {
            owner.flows.append(Flow(kind: .forAwait, subject: node.sequence, scope: scope))
        }
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        if elements.count == 3, elements[1].is(AssignmentExprSyntax.self),
            let local = elements[0].as(DeclReferenceExprSyntax.self)?.baseName.text,
            scope.lookup(local) != nil, elements[2].trimmedDescription != "nil"
        {
            scope.assign(local, elements[2])
        }
        guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self),
            let target = elements[0].as(MemberAccessExprSyntax.self), let base = target.base,
            base.trimmedDescription != "self"
        else { return .visitChildren }
        let name = target.declName.baseName.text
        let value = elements[2]
        if value.trimmedDescription == "self", name.lowercased().hasSuffix("delegate") || name == "dataSource" {
            owner.flows.append(Flow(kind: .delegate, subject: ExprSyntax(target), scope: scope))
        } else if value.is(ClosureExprSyntax.self) || (name.hasPrefix("on") && value.trimmedDescription != "nil") {
            owner.flows.append(Flow(kind: .callback, subject: ExprSyntax(target), scope: scope))
        }
        return .visitChildren
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    // MARK: Helpers

    private func accessLevel(_ modifiers: DeclModifierListSyntax) -> String {
        for modifier in modifiers {
            let text = modifier.name.text
            if ["open", "public", "package", "internal", "fileprivate", "private"].contains(text) {
                return modifier.detail == nil ? text : "internal"  // private(set) keeps getter access
            }
        }
        return "internal"
    }

    /// `Foo(…)`, `Foo<Bar>(…)`, `Foo.init(…)` → "Foo".
    /// `a.topAnchor.constraint(equalTo: b.bottomAnchor)`, `addSplitViewItem(x)`,
    /// `stack.addArrangedSubview(x)`, `NSStackView(views: [a, b])`: where the
    /// type places things, as written — `Tree` reads it back as words.
    private func recordPins(_ node: FunctionCallExprSyntax) {
        func anchor(_ expr: ExprSyntax?) -> (base: String, name: String)? {
            guard let member = expr?.as(MemberAccessExprSyntax.self) else { return nil }
            let name = member.declName.baseName.text
            guard name.hasSuffix("Anchor") else { return nil }
            return (member.base?.trimmedDescription ?? "", String(name.dropLast("Anchor".count)))
        }
        let callee = node.calledExpression
        if let member = callee.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if name == "constraint", let item = anchor(member.base) {
                let other = node.arguments.first.flatMap { anchor($0.expression) }
                owner.pins.append(Pin(item: item.base, anchor: item.name, other: other?.base, otherAnchor: other?.name))
                return
            }
            let arranged = [
                "addArrangedSubview": "stack", "insertArrangedSubview": "stack", "addSplitViewItem": "split",
            ]
            if let kind = arranged[name], let first = node.arguments.first {
                owner.pins.append(
                    Pin(item: first.expression.trimmedDescription, anchor: kind, other: member.base?.trimmedDescription)
                )
            }
            return
        }
        if let ref = callee.as(DeclReferenceExprSyntax.self), ref.baseName.text == "addSplitViewItem",
            let first = node.arguments.first
        {
            owner.pins.append(Pin(item: first.expression.trimmedDescription, anchor: "split"))
        }
        if constructedType(callee) == "NSStackView",
            let views = node.arguments.first(where: { $0.label?.text == "views" })?.expression.as(ArrayExprSyntax.self)
        {
            for element in views.elements {
                owner.pins.append(Pin(item: element.expression.trimmedDescription, anchor: "stack"))
            }
        }
    }

    private func constructedType(_ callee: ExprSyntax) -> String? {
        if let ref = callee.as(DeclReferenceExprSyntax.self), ref.baseName.text.first?.isUppercase == true {
            return ref.baseName.text
        }
        if let generic = callee.as(GenericSpecializationExprSyntax.self) {
            return constructedType(generic.expression)
        }
        if let member = callee.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init",
            let base = member.base
        {
            return constructedType(base)
        }
        // A nested type: `TranscriptTab.Context(…)`.
        if let member = callee.as(MemberAccessExprSyntax.self),
            member.declName.baseName.text.first?.isUppercase == true,
            let base = member.base, constructedType(base) != nil
        {
            return callee.trimmedDescription
        }
        return nil
    }

    /// Strips Combine operators off a `sink` receiver: `a.$b.map{…}.receive(on:)` → `a.$b`.
    private func publisherRoot(_ expr: ExprSyntax) -> ExprSyntax {
        var current = expr
        while let call = current.as(FunctionCallExprSyntax.self),
            let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            let base = member.base
        {
            current = base
        }
        return current
    }

    /// Every publisher a chain reads: its root, and what `combineLatest` / `merge` /
    /// `zip` join into it (`a.$x.combineLatest(a.$y) {…}` follows both).
    private func publisherRoots(_ expr: ExprSyntax) -> [ExprSyntax] {
        var joined: [ExprSyntax] = []
        var current = expr
        while let call = current.as(FunctionCallExprSyntax.self),
            let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            let base = member.base
        {
            if ["combineLatest", "merge", "zip"].contains(member.declName.baseName.text) {
                for argument in call.arguments where !argument.expression.is(ClosureExprSyntax.self) {
                    joined += publisherRoots(argument.expression).filter {
                        $0.is(MemberAccessExprSyntax.self) || $0.is(FunctionCallExprSyntax.self)
                    }
                }
            }
            current = base
        }
        return [current] + joined
    }

    private func argument(_ call: FunctionCallExprSyntax, _ label: String) -> String? {
        let arg =
            call.arguments.first { $0.label?.text == label }
            ?? (label == "for" ? call.arguments.first { $0.label == nil } : nil)
        return arg?.expression.trimmedDescription
    }

    /// The outermost `a.b.c` chains read inside a closure (not their prefixes).
    private func maximalMemberChains(in closure: ClosureExprSyntax) -> [ExprSyntax] {
        final class Collector: SyntaxVisitor {
            var chains: [ExprSyntax] = []
            override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                guard node.base != nil else { return .visitChildren }
                chains.append(ExprSyntax(node))
                return .skipChildren
            }
        }
        let collector = Collector(viewMode: .sourceAccurate)
        collector.walk(closure)
        return collector.chains
    }
}
