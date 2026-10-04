import AppKit
import DisplayModels

/// The composer's three pop-ups as the one menu (`MenuContent`, design 08
/// *Model*, *Effort*, *Permission mode*), each in a popover of one size:
/// Effort (240 wide) and Mode (300) a section head with its items, Mode's
/// Bypass past a hairline; Model 300 wide, a section per account under its
/// sticky head, *N More Models* expanding in place inside a list as tall as
/// when every model shows, and Fast Mode's switch under the scroll.
@MainActor
package enum ComposerMenu {
    /// What a chosen item stands for.
    /// The pull-down a menu opens from.
    package enum Control {
        case model
        case effort
        case mode
    }

    package enum Choice: Hashable {
        /// The item with this id (a model, an effort, a mode).
        case item(String)
        /// *N More Models* of the account section with this id.
        case more(UUID)
        /// The Fast Mode switch.
        case fastMode
    }

    /// The popovers' widths (`PO_KIND`).
    package static let effortWidth: CGFloat = 240
    package static let modeWidth: CGFloat = 300
    package static let modelWidth: CGFloat = 300

    /// Effort's or Mode's menu, `width` wide.
    package static func content(of menu: ComposerPresentation.Menu, width: CGFloat) -> MenuContent {
        var rows: [MenuContent.Row] = []
        for (index, section) in menu.sections.enumerated() {
            if index > 0 { rows.append(.separator) }
            if let header = section.header { rows.append(.header(.title(header, hint: section.headerHint))) }
            rows += section.items.map { .item(item($0)) }
        }
        return MenuContent(rows: rows, width: width)
    }

    /// The model list, with the sections in `expanded` unfolded; as tall as
    /// it is with every section unfolded.
    package static func modelContent(of model: ComposerPresentation, expanded: Set<UUID>) -> MenuContent {
        let fast = model.fastMode
        let footer = MenuContent.Row.item(
            MenuContent.Item(
                id: Choice.fastMode, title: String(localized: "Fast Mode", bundle: .module), subtitle: fast.subtitle,
                glyph: ComposerGlyph.menuImage(.fast), isEnabled: fast.isEnabled,
                trailing: .toggle(isOn: fast.isOn), toolTip: fast.subtitle))
        let all = Set(model.modelSections.map(\.id))
        return MenuContent(
            rows: modelRows(of: model, expanded: expanded), footer: [footer], width: modelWidth,
            listHeight: .expanded(modelRows(of: model, expanded: all)))
    }

    private static func modelRows(of model: ComposerPresentation, expanded: Set<UUID>) -> [MenuContent.Row] {
        var rows: [MenuContent.Row] = []
        if let header = model.modelPanelHeader { rows.append(.header(.title(header))) }
        for section in model.modelSections {
            let mark = ComposerGlyph.image(section.glyph, size: 14) ?? NSImage()
            rows.append(.header(.account(mark: mark, name: section.name, detail: section.detail, note: section.note)))
            rows += section.items.map { .item(item($0)) }
            if expanded.contains(section.id) {
                rows += section.foldedItems.map { .item(item($0)) }
            } else if !section.foldedItems.isEmpty {
                rows.append(
                    .item(
                        MenuContent.Item(
                            id: Choice.more(section.id),
                            title: String(localized: "\(section.foldedItems.count) More Models", bundle: .module),
                            isMore: true)))
            }
        }
        return rows
    }

    private static func item(_ item: ComposerPresentation.Item) -> MenuContent.Item {
        MenuContent.Item(
            id: Choice.item(item.id), title: item.title, subtitle: item.subtitle,
            glyph: item.glyph.flatMap(ComposerGlyph.menuImage), isChecked: item.isChecked, isEnabled: item.isEnabled,
            isDanger: item.isDanger,
            trailing: item.restarts ? .glyph(ComposerGlyph.image(.restart, size: 14) ?? NSImage()) : .none)
    }
}
