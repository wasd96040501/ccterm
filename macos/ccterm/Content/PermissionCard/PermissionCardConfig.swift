import Cocoa
import AgentSDK

// MARK: - Config types

struct PermissionCardConfig {
    let title: String
    let contentViews: [NSView]
    let options: [PermissionCardOption]
    let defaultSelectedIndex: Int

    init(title: String, contentViews: [NSView], options: [PermissionCardOption], defaultSelectedIndex: Int = 0) {
        self.title = title
        self.contentViews = contentViews
        self.options = options
        self.defaultSelectedIndex = defaultSelectedIndex
    }
}

struct PermissionCardOption {
    let title: String
    let makeDecision: (PermissionRequest, String?) -> PermissionDecision
    let inputConfig: InputConfig?

    init(title: String, makeDecision: @escaping (PermissionRequest, String?) -> PermissionDecision, inputConfig: InputConfig? = nil) {
        self.title = title
        self.makeDecision = makeDecision
        self.inputConfig = inputConfig
    }
}

struct InputConfig {
    let placeholder: String
    let submitOnEnter: Bool
}

// MARK: - View helpers

enum PermissionCardViewHelper {

    static func makeKeyValueRow(_ key: String, _ value: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = NSTextField(labelWithString: "\(key):")
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.font = .systemFont(ofSize: 11, weight: .medium)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        container.addSubview(keyLabel)

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .labelColor
        valueLabel.isSelectable = true
        valueLabel.maximumNumberOfLines = 6
        container.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            keyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            keyLabel.topAnchor.constraint(equalTo: container.topAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 4),
            valueLabel.topAnchor.constraint(equalTo: container.topAnchor),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            valueLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    static func makeMonoLabel(_ text: String, maxLines: Int) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .labelColor
        label.isSelectable = true
        label.maximumNumberOfLines = maxLines
        return label
    }

    static func makeDescriptionLabel(_ text: String, maxLines: Int) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        label.maximumNumberOfLines = maxLines
        return label
    }
}
