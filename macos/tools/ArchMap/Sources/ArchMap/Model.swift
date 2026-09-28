import SwiftSyntax

/// One parsed `.swift` file. `unit` is the directory it lives in, named
/// `<module>/<subdirs>` — the granularity the map reports at.
struct SourceFile {
    let path: String
    let module: String
    let unit: String
    let lines: Int
    let imports: [String]
    let tree: SourceFileSyntax
}

/// A name → type-or-expression table for one lexical scope (function params,
/// locals). Chained to its parent so a flow recorded mid-body can resolve
/// `store.$nodes` through `let store = …` or `init(store: LibraryStore)`.
final class Scope {
    let parent: Scope?
    var bindings: [String: Binding] = [:]

    enum Binding {
        case type(String)
        case expr(ExprSyntax)
    }

    init(parent: Scope?) { self.parent = parent }

    func lookup(_ name: String) -> Binding? { bindings[name] ?? parent?.lookup(name) }

    /// `x = value` on a local declared earlier (`var x: T?`): from here on `x`
    /// resolves through `value`, in the scope that declared it.
    func assign(_ name: String, _ value: ExprSyntax) {
        if bindings[name] != nil { bindings[name] = .expr(value) } else { parent?.assign(name, value) }
    }
}

struct Property {
    let name: String
    let type: String?
    let initializer: ExprSyntax?
    let isLet: Bool
    let isStatic: Bool
    let isComputed: Bool
    let modifiers: [String]
    let wrappers: [String]

    var isPrivate: Bool { modifiers.contains("private") || modifiers.contains("fileprivate") }
}

/// A non-type member, kept for surface / exposure accounting.
struct Member {
    let name: String
    let access: String
    let isOverride: Bool
    let isObjC: Bool
    let returnType: String?
    /// Declared in an `extension X: SomeProtocol` — there to satisfy that
    /// conformance, not chosen as the type's own surface.
    var isWitness = false
}

/// An expression some data-flow construct reads from or writes to, with the
/// scope it has to be resolved in.
struct Flow {
    enum Kind: String {
        case sink = "sink"
        case forAwait = "for-await"
        case tracking = "observes"
        case notifyPost = "posts"
        case notifyObserve = "notified-by"
        case kvo = "kvo"
        case callback = "sets-callback"
        case delegate = "sets-delegate"
        /// A publisher or stream handed to a constructed type's init.
        case passes = "passes"
    }

    let kind: Kind
    let subject: ExprSyntax
    let scope: Scope
    /// Notification name / key path / assigned value, when the subject alone
    /// doesn't say it.
    var detail: String? = nil
    /// For `passes`: the type constructed, and the init label (`Type(label:)`).
    var target: (type: String, label: String)? = nil
}

struct Access {
    let base: ExprSyntax
    let name: String
    let scope: Scope
}

/// A declared type, or `extension Foo` of a type outside the map (framework
/// types), or the file-level declarations of one file.
final class TypeInfo {
    let name: String
    let kind: String
    let file: String
    let module: String
    let unit: String
    let line: Int
    var endLine: Int
    var modifiers: [String] = []
    var attributes: [String] = []
    var inherits: [String] = []
    var nested: [String] = []
    var inits: [String] = []
    var initParams: Set<String> = []
    var properties: [Property] = []
    var members: [Member] = []

    var typeRefs: Set<String> = []
    var creates: [String] = []
    var hosts: [String] = []
    var flows: [Flow] = []
    var accesses: [Access] = []
    var tasks = 0
    /// Lines added by extensions declared in other files.
    var extensionLines = 0
    /// Set on an `extension` of a mapped type declared in another unit: its
    /// surface is merged into that type, but what it depends on stays here, in
    /// the unit that declares it — and `self` in it is that type.
    var extends: TypeInfo?

    init(name: String, kind: String, file: SourceFile, line: Int, endLine: Int) {
        self.name = name
        self.kind = kind
        self.file = file.path
        self.module = file.module
        self.unit = file.unit
        self.visibleModules = Set(file.imports).union([file.module])
        self.line = line
        self.endLine = endLine
    }

    /// Its own module plus what its file imports: the only places a name it
    /// uses can resolve to (TranscriptKit's `Transcript` is not AgentSDK's).
    let visibleModules: Set<String>

    var shortName: String { String(name.split(separator: ".").last ?? Substring(name)) }
    var lines: Int { endLine - line + 1 + extensionLines }
    var access: String {
        for level in ["open", "public", "package", "internal", "fileprivate", "private"]
        where modifiers.contains(level) { return level }
        return "internal"
    }
    var isObservable: Bool { attributes.contains("@Observable") }
    var isSwiftUIView: Bool { kind == "struct" && inherits.contains("View") }
}
