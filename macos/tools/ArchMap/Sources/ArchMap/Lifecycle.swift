import SwiftSyntax

/// What each view controller does in each phase of its life — builds its views, subscribes,
/// measures — read off the phase methods and the type's own methods they call. Only what runs
/// in the phase counts: a closure's body (a `sink`, a `DispatchQueue.main.async`) runs later
/// and is skipped. Feeds the lifecycle lines of `tree.md` and rule C1 (`macos/CLAUDE.md`
/// § Controllers & containment, *Size before content*).
struct Lifecycle {
    /// The phases in the order AppKit calls them.
    static let phases = [
        "loadView", "viewDidLoad", "viewWillAppear", "viewDidAppear", "viewDidLayout", "viewWillDisappear",
        "viewDidDisappear", "prepareForRemoval",
    ]
    /// Phases that run before a container has sized the view.
    static let beforeSize: Set<String> = ["loadView", "viewDidLoad", "viewWillAppear"]

    /// Calls and reads that need the view's real size: a layout pass, a table's rows, a
    /// scroll position, the bounds.
    static let sizeDependent: Set<String> = [
        "layoutSubtreeIfNeeded", "reloadData", "noteNumberOfRowsChanged", "noteHeightOfRows", "tile",
        "scrollToEndOfDocument", "scrollToBeginningOfDocument", "scrollRowToVisible", "scroll", "visibleRect",
        "bounds.width", "bounds.height", "bounds.size", "frame.width", "frame.height", "frame.size",
    ]
    private static let building: Set<String> = [
        "addSubview", "activate", "addChild", "addSplitViewItem", "addTabViewItem", "addArrangedSubview",
        "addLayoutGuide",
    ]
    private static let subscribing: Set<String> = ["sink", "assign", "addObserver", "observe", "values"]

    /// One method's own work: what it does directly, and the type's methods it calls.
    final class Body {
        var ops: Set<String> = []
        var calls: Set<String> = []
    }

    /// Type name → method name → body (overloads merged).
    let bodies: [String: [String: Body]]

    init(files: [SourceFile]) {
        let walker = Walker(viewMode: .sourceAccurate)
        for file in files { walker.walk(file.tree) }
        bodies = walker.bodies
    }

    /// What `phase` of `type` does, following the type's own methods it calls.
    func ops(of type: String, in phase: String) -> (ops: [String: String], subscribes: Bool, builds: Bool)? {
        guard let methods = bodies[type], methods[phase] != nil else { return nil }
        var found: [String: String] = [:]  // op → the method it is reached through
        var subscribes = false
        var builds = false
        var seen: Set<String> = []
        var queue = [phase]
        while let name = queue.first {
            queue.removeFirst()
            guard seen.insert(name).inserted, let body = methods[name] else { continue }
            for op in body.ops {
                if Self.sizeDependent.contains(op), found[op] == nil { found[op] = name }
                if Self.subscribing.contains(op) { subscribes = true }
                if Self.building.contains(op) { builds = true }
            }
            queue += body.calls.filter { methods[$0] != nil && !Self.phases.contains($0) }
        }
        return (found, subscribes, builds)
    }

    /// One line per phase that does something: `viewDidLoad subscribes · viewDidAppear measures (reloadData)`.
    func summary(of type: String) -> String? {
        var parts: [String] = []
        for phase in Self.phases {
            guard let done = ops(of: type, in: phase) else { continue }
            var verbs: [String] = []
            if done.builds { verbs.append("builds") }
            if done.subscribes { verbs.append("subscribes") }
            if !done.ops.isEmpty {
                verbs.append("measures (" + done.ops.keys.sorted().joined(separator: ", ") + ")")
            }
            if !verbs.isEmpty { parts.append(phase + " " + verbs.joined(separator: ", ")) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private final class Walker: SyntaxVisitor {
        var bodies: [String: [String: Body]] = [:]
        private var owners: [String] = []
        private var body: Body?
        private var bodyNode: SyntaxIdentifier?
        private var closureDepth = 0

        private func push(_ name: String) { owners.append((owners.last.map { $0 + "." } ?? "") + name) }

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            push(node.name.text)
            return .visitChildren
        }
        override func visitPost(_ node: ClassDeclSyntax) { owners.removeLast() }
        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            push(node.name.text)
            return .visitChildren
        }
        override func visitPost(_ node: StructDeclSyntax) { owners.removeLast() }
        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            push(node.name.text)
            return .visitChildren
        }
        override func visitPost(_ node: EnumDeclSyntax) { owners.removeLast() }
        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            owners.append(node.extendedType.trimmedDescription)
            return .visitChildren
        }
        override func visitPost(_ node: ExtensionDeclSyntax) { owners.removeLast() }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            guard let owner = owners.last, body == nil else { return .skipChildren }
            let name = node.name.text
            let entry = bodies[owner, default: [:]][name] ?? Body()
            bodies[owner, default: [:]][name] = entry
            body = entry
            bodyNode = node.id
            return .visitChildren
        }
        override func visitPost(_ node: FunctionDeclSyntax) {
            if node.id == bodyNode { (body, bodyNode) = (nil, nil) }
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            closureDepth += 1
            return .visitChildren
        }
        override func visitPost(_ node: ClosureExprSyntax) { closureDepth -= 1 }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard let body, closureDepth == 0 else { return .visitChildren }
            let callee = node.calledExpression
            if let ref = callee.as(DeclReferenceExprSyntax.self) {
                body.calls.insert(ref.baseName.text)
                body.ops.insert(ref.baseName.text)
            } else if let member = callee.as(MemberAccessExprSyntax.self) {
                let name = member.declName.baseName.text
                body.ops.insert(name)
                if member.base == nil || member.base?.trimmedDescription == "self" { body.calls.insert(name) }
            }
            return .visitChildren
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            guard let body, closureDepth == 0, let base = node.base?.as(MemberAccessExprSyntax.self) else {
                return .visitChildren
            }
            // `view.bounds.width`, `scrollView.frame.size`: a read of the laid-out size.
            let pair = base.declName.baseName.text + "." + node.declName.baseName.text
            if Lifecycle.sizeDependent.contains(pair) { body.ops.insert(pair) }
            if node.declName.baseName.text == "visibleRect" { body.ops.insert("visibleRect") }
            return .visitChildren
        }
    }
}
