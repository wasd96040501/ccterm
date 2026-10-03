import AppKit
import Components

/// The grouped form of Settings: sections of rows with their controls, a row
/// whose description is an error, and the toast a sheet shows.
enum FormSpecimen {
    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "Settings form",
            note:
                "The grouped form of Settings: a row is a title with its control at the trailing edge, and a line "
                + "under both when there is something to say; an error colours only the words that are wrong. A sheet "
                + "notes what a paste filled with a toast.",
            specimens: [
                .init(title: "Rows — a field, a pop-up, a secret", view: rows(), width: Host.paneForm, height: 168),
                .init(title: "A description as an error, and a toast", view: notes(), width: Host.paneForm, height: 150),
            ])
    }

    private static func rows() -> NSView {
        let provider = FormPopUpButton()
        provider.addItem(title: "Anthropic", detail: nil, representedObject: nil)
        provider.addItem(title: "Auth Token", detail: "Authorization: Bearer", representedObject: nil)
        let key = FormSecretField(placeholder: "sk-ant-…")
        key.configure(value: "sk-ant-api03-abcdef", masked: "sk-ant-•••••cdef")
        let group = FormGroupView(rows: [
            FormRowView(title: "Name", accessory: FormTextField(placeholder: "Work")),
            FormRowView(title: "Provider", accessory: provider),
            FormRowView(title: "API Key", accessory: key),
        ])
        return FormView(sections: [FormSectionView(title: "Account", content: group)])
    }

    private static func notes() -> NSView {
        let url = FormRowView(title: "Base URL", accessory: FormTextField(placeholder: "https://", monospaced: true))
        url.detail = "Not a URL. Requests go to api.anthropic.com."
        url.isDetailError = true
        url.detailErrorLength = 10
        let toast = ToastView()
        let show = ToastButton(toast: toast)
        let button = FormRowView(title: "A note after a paste", accessory: show)
        let form = FormView(sections: [
            FormSectionView(title: "Endpoint", content: FormGroupView(rows: [url, button]))
        ])
        let container = NSView()
        for view in [form, toast] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: container.topAnchor),
            form.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        ])
        return container
    }
}

/// Shows its toast when pressed.
private final class ToastButton: NSButton {
    private let toast: ToastView

    init(toast: ToastView) {
        self.toast = toast
        super.init(frame: .zero)
        title = "Show Toast"
        bezelStyle = .push
        target = self
        action = #selector(showToast(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func showToast(_ sender: Any?) {
        toast.show("Filled from the clipboard")
    }
}
