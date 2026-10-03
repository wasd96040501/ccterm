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
                .init(
                    title: "Signed in, three providers — ⓘ, a row's menu, Add Provider…",
                    view: AccountsHost(subscription: .signedIn(subscription), providers: providers), height: nil),
                .init(
                    title: "Signed out, no providers — Sign In… waits on the browser",
                    view: AccountsHost(subscription: .signedOut, providers: []), height: nil),
                .init(title: "The login not read yet", view: AccountsHost(subscription: .checking), height: nil),
                .init(
                    title: "Environment variables — click a row, then Space, Return, Delete or +",
                    view: VariablesHost(), height: nil),
                .init(title: "Signing in", view: SignInHost(), height: nil),
            ])
    }

    /// The design's subscription and providers, worded as the app words them.
    static let subscription = AccountRowContent(
        title: "name@example.com", subtitle: "Claude Max · Personal", mark: .claude, accessory: .info)

    static let providers = [
        ("Local Proxy", "127.0.0.1:8788 · claude-opus-5-5[1m]"),
        ("Team Relay", "relay.example.com · claude-opus-5-5[1m]"),
        ("GLM", "127.0.0.1:8788 · glm-5.2[1m]"),
    ].map { title, subtitle in
        ProvidersSectionViewController.Row(
            id: UUID(), content: AccountRowContent(title: title, subtitle: subtitle, mark: .provider, accessory: .info))
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

/// The Accounts pane's two sections, as the pane stacks them, driven by a
/// stand-in for the app: Sign In… waits on the browser until Cancel, Sign
/// Out… signs out, Add Provider… and Duplicate add a row and flash it,
/// Delete… removes one, ⓘ flashes it.
private final class AccountsHost: NSView, SubscriptionSectionViewControllerDelegate,
    ProvidersSectionViewControllerDelegate
{
    private let subscriptionSection = SubscriptionSectionViewController()
    private let providersSection = ProvidersSectionViewController()
    private var providers: [ProvidersSectionViewController.Row]

    /// `providers` nil leaves the providers section out.
    init(subscription: SubscriptionSectionViewController.State, providers: [ProvidersSectionViewController.Row]? = nil)
    {
        self.providers = providers ?? []
        super.init(frame: .zero)
        subscriptionSection.delegate = self
        providersSection.delegate = self
        subscriptionSection.show(subscription)
        var sections = [subscriptionSection.view]
        if let providers {
            providersSection.show(providers)
            sections.append(providersSection.view)
        }
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 30
        let inset = AccountsSpecimen.inset(stack)
        inset.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inset)
        NSLayoutConstraint.activate([
            inset.topAnchor.constraint(equalTo: topAnchor),
            inset.leadingAnchor.constraint(equalTo: leadingAnchor),
            inset.trailingAnchor.constraint(equalTo: trailingAnchor),
            inset.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func subscriptionSectionDidRequestOpen(_ section: SubscriptionSectionViewController) {}

    func subscriptionSectionDidRequestSignIn(_ section: SubscriptionSectionViewController) {
        section.show(.signingIn(browserURL: URL(string: "https://claude.ai/oauth/authorize")))
    }

    func subscriptionSectionDidCancelSignIn(_ section: SubscriptionSectionViewController) {
        section.show(.signedOut)
    }

    func subscriptionSectionDidRequestSignOut(_ section: SubscriptionSectionViewController) {
        section.show(.signedOut)
    }

    func providersSectionDidRequestAdd(_ section: ProvidersSectionViewController) {
        add(
            AccountRowContent(
                title: "New Provider", subtitle: "No base URL · Default model", mark: .provider, accessory: .info))
    }

    func providersSectionDidRequestImport(_ section: ProvidersSectionViewController) {
        add(
            AccountRowContent(
                title: "relay", subtitle: "relay.example.com · Default model", mark: .provider, accessory: .info))
    }

    func providersSectionCanImport(_ section: ProvidersSectionViewController) -> Bool { true }

    func providersSection(_ section: ProvidersSectionViewController, didOpen id: UUID) {
        section.flash([id])
    }

    func providersSection(_ section: ProvidersSectionViewController, didRequestDuplicate id: UUID) {
        guard let row = providers.first(where: { $0.id == id }) else { return }
        var copy = row.content
        copy.title += " Copy"
        add(copy)
    }

    func providersSection(_ section: ProvidersSectionViewController, didRequestDelete id: UUID) {
        providers.removeAll { $0.id == id }
        section.show(providers)
    }

    private func add(_ content: AccountRowContent) {
        let row = ProvidersSectionViewController.Row(id: UUID(), content: content)
        providers.append(row)
        providersSection.show(providers)
        providersSection.flash([row.id])
    }
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
