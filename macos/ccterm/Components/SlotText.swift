import SwiftUI
import AppKit

/// Slot-machine style vertical scrolling text using CATransition.
/// Wraps an NSTextField with push-from-bottom transition.
/// Supports an optional SF Symbol icon that scrolls together with the text.
struct SlotText: NSViewRepresentable {
    var text: String
    var ordinal: Int
    var font: NSFont = .systemFont(ofSize: 12, weight: .medium)
    var color: NSColor = .labelColor
    var icon: String? = nil
    var iconSize: CGFloat = 12
    var animated: Bool = true

    func makeNSView(context: Context) -> SlotTextNSView {
        let view = SlotTextNSView()
        view.label.font = font
        view.label.textColor = color
        view.updateContent(text: text, icon: icon, iconSize: iconSize, color: color)
        view.currentWidth = view.contentWidth
        view.widthConstraint.constant = view.currentWidth
        context.coordinator.previousOrdinal = ordinal
        return view
    }

    func updateNSView(_ nsView: SlotTextNSView, context: Context) {
        let coordinator = context.coordinator

        nsView.label.font = font
        nsView.label.textColor = color

        let oldContent = nsView.label.attributedStringValue.string
        let newContent = nsView.buildAttributedString(text: text, icon: icon, iconSize: iconSize, color: color).string

        if oldContent != newContent {
            let shouldAnimate = animated && coordinator.previousOrdinal != ordinal

            if shouldAnimate {
                let transition = CATransition()
                transition.type = .push
                transition.subtype = .fromBottom
                transition.duration = 0.25
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                nsView.label.layer?.add(transition, forKey: "slot")
            }

            nsView.updateContent(text: text, icon: icon, iconSize: iconSize, color: color)
            let newWidth = nsView.contentWidth

            if shouldAnimate && newWidth != nsView.currentWidth {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    nsView.widthConstraint.animator().constant = newWidth
                }
                nsView.currentWidth = newWidth
            } else {
                nsView.widthConstraint.constant = newWidth
                nsView.currentWidth = newWidth
            }

            nsView.invalidateIntrinsicContentSize()
        } else {
            // Text unchanged but color might have changed
            nsView.updateContent(text: text, icon: icon, iconSize: iconSize, color: color)
        }

        coordinator.previousOrdinal = ordinal
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var previousOrdinal: Int = 0
    }
}

/// Hosts a single-line NSTextField with animated width.
final class SlotTextNSView: NSView {
    let label: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.isEditable = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.lineBreakMode = .byClipping
        tf.maximumNumberOfLines = 1
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.wantsLayer = true
        return tf
    }()

    lazy var widthConstraint: NSLayoutConstraint = {
        widthAnchor.constraint(equalToConstant: 0)
    }()

    var currentWidth: CGFloat = 0

    var contentWidth: CGFloat {
        label.attributedStringValue.size().width
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: currentWidth, height: label.intrinsicContentSize.height)
    }

    func updateContent(text: String, icon: String?, iconSize: CGFloat, color: NSColor) {
        label.attributedStringValue = buildAttributedString(
            text: text, icon: icon, iconSize: iconSize, color: color
        )
    }

    func buildAttributedString(text: String, icon: String?, iconSize: CGFloat, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()

        if let iconName = icon {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig) {
                let attachment = NSTextAttachment()
                attachment.image = image
                // Center icon vertically with text
                let font = label.font ?? .systemFont(ofSize: 11)
                let yOffset = (font.capHeight - image.size.height) / 2
                attachment.bounds = CGRect(
                    x: 0, y: yOffset,
                    width: image.size.width, height: image.size.height
                )
                let iconString = NSMutableAttributedString(attachment: attachment)
                iconString.addAttribute(.foregroundColor, value: color,
                                        range: NSRange(location: 0, length: iconString.length))
                result.append(iconString)
                // Spacing between icon and text
                result.append(NSAttributedString(string: " ",
                    attributes: [.font: NSFont.systemFont(ofSize: 4)]))
            }
        }

        result.append(NSAttributedString(string: text, attributes: [
            .font: label.font ?? .systemFont(ofSize: 11),
            .foregroundColor: color,
        ]))

        return result
    }
}
