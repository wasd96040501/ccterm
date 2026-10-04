import SwiftSyntax

/// The placement rules of `macos/CLAUDE.md` § Where code lives, read off the
/// syntax: the app drawing (P1), a package importing past its arrow (P2), and
/// an app type that reaches for AppKit or `Components` though it binds nothing
/// (P3). Each is a fact about one file, so each finding names its line.
struct Placement {
    let index: Index
    let files: [SourceFile]
    /// The modules built from this repo, as against Apple's frameworks.
    let repoModules: Set<String>
    let isComponent: (TypeInfo) -> Bool

    static let app = "ccterm"

    /// What a package may import from the repo, and — when it may import no
    /// framework but these — which frameworks.
    static let arrows: [String: (repo: Set<String>, frameworks: Set<String>?)] = [
        "DisplayModels": ([], ["Foundation"]),
        "Components": (["DisplayModels"], nil),
    ]

    /// AppKit views and controls the app may make: a container, and system UI
    /// drawn as the system draws it.
    static let allowedViews: Set<String> = ["NSView", "NSStackView"]
    static let viewSuffixes = [
        "View", "Field", "Button", "Control", "Box", "Indicator", "Popover", "Slider", "Switch", "Well", "Picker",
        "Menu", "MenuItem",
    ]
    /// Members that set how a view looks.
    static let looks: Set<String> = [
        "font", "textColor", "backgroundColor", "layer", "wantsLayer", "contentTintColor", "drawsBackground",
    ]
    /// Types only drawing code names.
    static let drawingTypes: Set<String> = [
        "NSColor", "NSFont", "NSBezierPath", "NSGradient", "NSShadow", "CALayer", "CAShapeLayer", "CGContext",
    ]
    /// A view's drawing overrides.
    static let drawingOverrides: Set<String> = ["draw", "updateLayer", "wantsUpdateLayer", "makeBackingLayer"]
    /// What an app type imports only to bind views.
    static let viewImports: Set<String> = ["AppKit", "Components", "SwiftUI"]
    /// The app's entry: the composition root and the SwiftUI shell around it.
    static let entryConformances: Set<String> = ["NSApplicationDelegate", "App", "Commands"]

    func findings() -> [Rules.Finding] {
        var found: [Rules.Finding] = []
        for file in files {
            let converter = SourceLocationConverter(fileName: file.path, tree: file.tree)
            if file.module == Self.app {
                let drawing = Drawing(converter: converter)
                drawing.walk(file.tree)
                found += drawing.hits.map { Rules.Finding(rule: "P1", file: file.path, line: $0.line, what: $0.what) }
            }
            if let arrow = Self.arrows[file.module] {
                for statement in file.tree.statements {
                    guard let decl = statement.item.as(ImportDeclSyntax.self) else { continue }
                    let name = decl.path.first?.name.text ?? ""
                    let allowed =
                        repoModules.contains(name)
                        ? arrow.repo.contains(name) : (arrow.frameworks?.contains(name) ?? true)
                    guard !allowed else { continue }
                    found.append(
                        Rules.Finding(
                            rule: "P2", file: file.path, line: decl.startLocation(converter: converter).line,
                            what: "`\(file.module)` imports `\(name)`"))
                }
            }
        }
        // P3: a type that is no component, coordinator or entry, and builds no
        // component, declared in a file that imports a view framework.
        for type in index.types
        where type.module == Self.app && ["class", "struct", "enum", "actor"].contains(type.kind) {
            guard let file = files.first(where: { $0.path == type.file }),
                let reached = file.imports.first(where: Self.viewImports.contains),
                !isComponent(type), !type.name.hasSuffix("Coordinator"),
                !type.inherits.contains(where: Self.entryConformances.contains),
                !type.creates.contains(where: { index.lookup($0, from: type).map(isComponent) ?? false }),
                !index.types.contains(where: { $0 !== type && $0.file == type.file && isComponent($0) })
            else { continue }
            found.append(
                Rules.Finding(
                    rule: "P3", file: type.file, line: type.line,
                    what: "`\(type.shortName)` imports `\(reached)` but binds no view"))
        }
        return found
    }

    /// The places one file of the app draws.
    private final class Drawing: SyntaxVisitor {
        let converter: SourceLocationConverter
        var hits: [(line: Int, what: String)] = []

        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        private func hit(_ node: some SyntaxProtocol, _ what: String) {
            hits.append((node.startLocation(converter: converter).line, what))
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let name = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
                name.hasPrefix("NS"), !Placement.allowedViews.contains(name),
                Placement.viewSuffixes.contains(where: name.hasSuffix)
            {
                hit(node, "makes an `\(name)`")
            }
            return .visitChildren
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            let name = node.declName.baseName.text
            if Placement.looks.contains(name), node.base != nil { hit(node, "sets `.\(name)`") }
            return .visitChildren
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            if Placement.drawingTypes.contains(node.baseName.text) { hit(node, "names `\(node.baseName.text)`") }
            return .visitChildren
        }

        override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
            if Placement.drawingTypes.contains(node.name.text) { hit(node, "names `\(node.name.text)`") }
            return .visitChildren
        }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            if node.modifiers.contains(where: { $0.name.text == "override" }),
                Placement.drawingOverrides.contains(node.name.text)
            {
                hit(node, "overrides `\(node.name.text)`")
            }
            return .visitChildren
        }

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            let name = node.bindings.first?.pattern.trimmedDescription ?? ""
            if node.modifiers.contains(where: { $0.name.text == "override" }),
                Placement.drawingOverrides.contains(name)
            {
                hit(node, "overrides `\(name)`")
            }
            return .visitChildren
        }
    }
}
