#if DEBUG

import AgentSDK
import SwiftUI

/// Drives the full chat surface — real `ChatHistoryView`, real
/// `ChatRestingBar`, real `PermissionCardView` — against a mocked
/// `SessionManager` / `Session` pair so the `permission card ↔ input
/// bar ↔ transcript` geometry can be inspected end-to-end without a
/// live CLI.
///
/// History is seeded once from `TranscriptDemoView.initialBlocks`
/// (already an internal fixture). A floating control panel in the
/// **bottom-trailing** corner — deliberately offset from the input
/// bar's bottom-centered position so it never overlaps the bar or its
/// permission card overlay — flips entries into / out of
/// `runtime.pendingPermissions`, which the card observes by way of
/// the `@Observable` runtime.
struct PermissionSessionDemoView: View {
    @State private var seed = Seed.make()
    @State private var selectedKindIndex: Int = 0

    var body: some View {
        ZStack {
            ChatHistoryView(sessionId: seed.sessionId, showsSearch: false)
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .bottom) {
                    ChatRestingBar(
                        sessionId: seed.sessionId,
                        draftKey: seed.sessionId,
                        onSubmit: { _ in },
                        onAttachRect: { _ in },
                        onPillRect: { _ in }
                    )
                }
        }
        .environment(seed.manager)
        .overlay(alignment: .bottomTrailing) {
            ControlPanel(
                selection: $selectedKindIndex,
                fixtures: Self.kindFixtures,
                isCurrentShown: isCurrentShown,
                hasAny: !seed.session.pendingPermissions.isEmpty,
                onShow: showCurrent,
                onHide: hideAll
            )
            .padding(20)
        }
        .task {
            seed.seedHistoryIfNeeded()
        }
    }

    // MARK: - Toggling pendingPermissions

    private var isCurrentShown: Bool {
        guard let pending = seed.session.pendingPermissions.first else { return false }
        return pending.id == Self.kindFixtures[selectedKindIndex].id
    }

    private func showCurrent() {
        guard let runtime = seed.session.runtime else { return }
        let item = Self.kindFixtures[selectedKindIndex]
        let pending = PendingPermission(
            id: item.id,
            request: item.request,
            // Card button taps land here; mirror the production runtime
            // by popping the entry off the pending list. We don't care
            // about the decision payload — this is a layout demo.
            respond: { [weak runtime] _ in
                runtime?.pendingPermissions.removeAll { $0.id == item.id }
            }
        )
        runtime.pendingPermissions = [pending]
    }

    private func hideAll() {
        seed.session.runtime?.pendingPermissions.removeAll()
    }

    // MARK: - Fixture pool

    fileprivate struct KindFixture: Identifiable {
        let id: String
        let label: String
        let request: PermissionRequest
    }

    fileprivate static let kindFixtures: [KindFixture] = [
        KindFixture(
            id: "demo-bash",
            label: "Bash · shell command",
            request: .makePreview(
                requestId: "demo-bash",
                toolName: "Bash",
                input: [
                    "command": "git push --force origin main",
                    "description": "Force-push the rebased branch",
                ])),
        KindFixture(
            id: "demo-edit",
            label: "Edit · file diff",
            request: .makePreview(
                requestId: "demo-edit",
                toolName: "Edit",
                input: [
                    "file_path": "/Users/example/Project/Sources/Greeter.swift",
                    "old_string": "print(\"hello\")",
                    "new_string": "print(\"hello, world\")",
                ])),
        KindFixture(
            id: "demo-edit-long",
            label: "Edit · long diff (tests 780pt cap)",
            request: .makePreview(
                requestId: "demo-edit-long",
                toolName: "Edit",
                input: [
                    "file_path": "/Users/example/Project/Sources/Localized.swift",
                    "old_string": (0..<25)
                        .map { "    case option\($0): return \"option-\($0)\"" }
                        .joined(separator: "\n"),
                    "new_string": (0..<25)
                        .map {
                            "    case option\($0): return String(localized: \"option-\($0)\")"
                        }
                        .joined(separator: "\n"),
                ])),
        KindFixture(
            id: "demo-webfetch",
            label: "WebFetch",
            request: .makePreview(
                requestId: "demo-webfetch",
                toolName: "WebFetch",
                input: [
                    "url": "https://docs.swift.org/swift-book/",
                    "prompt": "Summarise the section on protocols.",
                ])),
        KindFixture(
            id: "demo-enter-plan",
            label: "EnterPlanMode",
            request: .makePreview(
                requestId: "demo-enter-plan",
                toolName: "EnterPlanMode",
                input: [:])),
        KindFixture(
            id: "demo-ask",
            label: "AskUserQuestion",
            request: .makePreview(
                requestId: "demo-ask",
                toolName: "AskUserQuestion",
                input: [
                    "questions": [
                        [
                            "question":
                                "Should we keep backwards-compatibility shims for the old API?",
                            "header": "Compat",
                            "multiSelect": false,
                            "options": [
                                [
                                    "label": "Yes, keep them",
                                    "description": "Existing clients still depend on them",
                                ],
                                [
                                    "label": "No, remove them",
                                    "description": "Cleaner break, faster releases",
                                ],
                            ],
                        ]
                    ]
                ])),
    ]
}

// MARK: - Control panel

/// Floating control surface anchored to the **bottom-trailing** corner.
/// Bottom-centered would collide with the input bar / permission card
/// stack; the trailing corner keeps both visible at the same time.
private struct ControlPanel: View {
    @Binding var selection: Int
    let fixtures: [PermissionSessionDemoView.KindFixture]
    let isCurrentShown: Bool
    let hasAny: Bool
    let onShow: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permission Card Controller")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Picker("Kind", selection: $selection) {
                ForEach(Array(fixtures.enumerated()), id: \.offset) { index, fx in
                    Text(fx.label).tag(index)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 240)
            HStack(spacing: 8) {
                Button(action: onShow) {
                    Label("Show", systemImage: "eye")
                }
                .disabled(isCurrentShown)
                Button(action: onHide) {
                    Label("Hide", systemImage: "eye.slash")
                }
                .disabled(!hasAny)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
    }
}

// MARK: - Seed

/// One-shot fixture container. Built once at `init` of the demo view
/// (via `@State`'s default initializer) and persisted across re-renders.
/// Owns the in-memory repository, the manager, and the cached `Session`
/// the demo wires up — all live for the demo view's lifetime.
@MainActor
private struct Seed {
    let sessionId: String
    let manager: SessionManager
    let session: Session
    let controller: Transcript2Controller
    /// Reference type wrapping a single Bool so a `struct` `Seed` can
    /// still flip "history seeded" idempotently from a `let` binding.
    private let seedToken = SeedToken()

    static func make() -> Seed {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        let record = SessionRecord(
            sessionId: sid,
            title: "Permission Demo",
            cwd: "/tmp/demo",
            status: .created
        )
        repo.save(record)
        let manager = SessionManager(
            repository: repo,
            cliClientFactory: { _ in FakeCLIClient() }
        )
        // `session(_:)` materialises the cached `Session` (active phase,
        // since a record exists). Force-unwrap is safe — we just wrote
        // the record above.
        let session = manager.session(sid)!
        return Seed(
            sessionId: sid,
            manager: manager,
            session: session,
            controller: session.controller
        )
    }

    func seedHistoryIfNeeded() {
        guard !seedToken.done else { return }
        seedToken.done = true
        controller.setHistory(TranscriptDemoView.initialBlocks)
    }
}

@MainActor
private final class SeedToken {
    var done: Bool = false
}

#endif
