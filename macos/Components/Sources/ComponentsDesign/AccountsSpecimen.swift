import AppKit
import Components

/// Accounts' parts (design/settings, *Accounts*): an account's row in each of
/// its states, the API Providers group with nothing in it, an account's
/// variable list, and the sheet shown while signing in. The sample data is
/// the design's.
enum AccountsSpecimen {
    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "Accounts",
            note:
                "An account is what a session runs as: at most one subscription, any number of API providers. A row "
                + "is 52 tall — a 28-point mark, the name over one secondary line, and ⓘ at the trailing edge; signed "
                + "out, the subscription's row asks to sign in instead. With no providers the group is an empty state, "
                + "as ContentUnavailableView draws one.",
            specimens: [
                .init(title: "Rows — signed in, two providers", view: rows(), height: nil),
                .init(title: "Rows — signed out, and still checking", view: signedOut(), height: nil),
                .init(title: "No API providers", view: empty(), height: nil),
                .init(
                    title: "Environment variables — click a row, then Space, Return, Delete or +",
                    view: VariablesHost(), height: nil),
                .init(title: "Signing in", view: SignInHost(), height: nil),
            ])
    }

    private static func rows() -> NSView {
        let rows = [
            AccountRowContent(
                title: "name@example.com", subtitle: "Claude Max · Personal", mark: .claude, accessory: .info),
            AccountRowContent(
                title: "Local Proxy", subtitle: "127.0.0.1:8788 · claude-opus-5-5[1m]", mark: .provider,
                accessory: .info),
            AccountRowContent(
                title: "Team Relay", subtitle: "relay.example.com · claude-opus-5-5[1m]", mark: .provider,
                accessory: .info),
        ]
        .map(row)
        rows.last?.menu = NSMenu.sample(["Details…", "Duplicate", "Delete…"])
        return form(title: "Subscription · API Providers", rows: rows)
    }

    private static func signedOut() -> NSView {
        form(
            title: "Subscription",
            rows: [
                row(
                    AccountRowContent(
                        title: "Not signed in", subtitle: "Use your Claude Pro or Max plan.", mark: .claudeDimmed,
                        accessory: .button("Sign In…"))),
                row(
                    AccountRowContent(
                        title: "Subscription", subtitle: "Checking…", mark: .claudeDimmed, accessory: .progress)),
            ])
    }

    private static func empty() -> NSView {
        let empty = ProvidersEmptyView()
        empty.addButton.isImportEnabled = { true }
        return form(title: "API Providers", rows: [empty])
    }

    private static func row(_ content: AccountRowContent) -> AccountRowView {
        let row = AccountRowView()
        row.configure(with: content)
        row.onOpen = { [weak row] in row?.flash() }
        return row
    }

    private static func form(title: String, rows: [NSView]) -> NSView {
        inset(FormSectionView(title: title, content: FormGroupView(rows: rows)))
    }

    /// `view` 20 in from every edge, as a form insets its sections.
    static func inset(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])
        return container
    }
}

extension NSMenu {
    /// A context menu of these titles, each enabled and doing nothing.
    fileprivate static func sample(_ titles: [String]) -> NSMenu {
        let menu = NSMenu()
        for title in titles {
            let item = NSMenuItem(title: title, action: #selector(SampleMenuTarget.choose(_:)), keyEquivalent: "")
            item.target = SampleMenuTarget.shared
            menu.addItem(item)
        }
        return menu
    }
}

/// What a sample menu's items are sent to: nothing happens.
private final class SampleMenuTarget: NSObject {
    static let shared = SampleMenuTarget()

    @objc func choose(_ sender: Any?) {}
}

/// The design's Local Proxy variables in the real list, which edits them
/// as the app's editor does: every edit comes back as the next rows.
private final class VariablesHost: NSView, EnvironmentVariablesViewControllerDelegate {
    private let list = EnvironmentVariablesViewController()
    private var variables: [(isEnabled: Bool, name: String, value: String)] = [
        (true, "NO_PROXY", "127.0.0.1,localhost"),
        (true, "API_TIMEOUT_MS", "3000000"),
        (true, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"),
        (true, "CLAUDE_CODE_EFFORT_LEVEL", "xhigh"),
        (true, "ANTHROPIC_AUTH_TOKEN", "sk-proxy-example-4b0e9d2c7c1e"),
        (false, "ENABLE_TOOL_SEARCH", "false"),
    ]

    init() {
        super.init(frame: .zero)
        list.delegate = self
        let form = FormSectionView(title: "Environment Variables", content: FormGroupView(rows: [list.view]))
        form.translatesAutoresizingMaskIntoConstraints = false
        addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            form.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            list.view.heightAnchor.constraint(equalToConstant: EnvironmentVariablesViewController.height),
        ])
        show()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The rows as the app words them: a secret's value masked, a warning on
    /// a variable that Settings sets itself.
    private func show() {
        list.configure(
            with: variables.map { variable in
                let secret = variable.name.hasSuffix("_TOKEN") || variable.name.hasSuffix("_KEY")
                return EnvironmentRow(
                    isEnabled: variable.isEnabled, name: variable.name,
                    displayValue: secret ? String(variable.value.prefix(8)) + "•••••" : variable.value,
                    warning: variable.name == "ANTHROPIC_AUTH_TOKEN"
                        ? "The provider's API Key sets this; this row is ignored." : nil)
            })
    }

    func environmentVariables(_ list: EnvironmentVariablesViewController, didToggleAt index: Int) {
        variables[index].isEnabled.toggle()
        show()
    }

    func environmentVariables(_ list: EnvironmentVariablesViewController, didSetName name: String, at index: Int) {
        variables[index].name = name
        show()
    }

    func environmentVariables(_ list: EnvironmentVariablesViewController, didSetValue value: String, at index: Int) {
        variables[index].value = value
        show()
    }

    func environmentVariablesDidAdd(_ list: EnvironmentVariablesViewController) -> Int {
        variables.append((true, "", ""))
        show()
        return variables.count - 1
    }

    func environmentVariables(_ list: EnvironmentVariablesViewController, didRemoveAt index: Int) {
        variables.remove(at: index)
        show()
    }

    func environmentVariables(_ list: EnvironmentVariablesViewController, valueAt index: Int) -> String {
        variables[index].value
    }
}

/// The sign-in sheet's content, as the sheet shows it, centred in its card.
private final class SignInHost: NSView {
    private let sheet = SignInViewController()

    init() {
        super.init(frame: .zero)
        sheet.configure(browserURL: URL(string: "https://claude.ai/oauth/authorize"))
        let content = sheet.view
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            content.widthAnchor.constraint(equalToConstant: sheet.preferredContentSize.width),
            content.heightAnchor.constraint(equalToConstant: sheet.preferredContentSize.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
