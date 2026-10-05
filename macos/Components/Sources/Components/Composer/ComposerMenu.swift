import AppKit
import DisplayModels

/// The composer's three menus (design 08 *Model*, *Effort*, *Permission
/// mode*) as `MenuContent`: Effort (240 wide) and Mode (300) a head with its
/// items, Mode's Bypass past a hairline; Model 300 wide, every model under its
/// account's head, and the Fast Mode switch under the list.
@MainActor
package enum ComposerMenu {
    /// The button a menu opens from.
    package enum Control {
        case model
        case effort
        case mode
    }

    /// What a chosen item stands for.
    package enum Choice: Hashable {
        /// The item with this id (a model, an effort, a mode).
        case item(String)
        /// The Fast Mode switch.
        case fastMode
    }

    package static func content(of control: Control, in model: ComposerPresentation) -> MenuContent {
        switch control {
        case .model: modelContent(of: model)
        case .effort: content(of: model.effortMenu, minWidth: 240)
        case .mode: content(of: model.modeMenu, minWidth: 300)
        }
    }

    private static func content(of menu: ComposerPresentation.Menu, minWidth: CGFloat) -> MenuContent {
        var rows: [MenuContent.Row] = []
        for (index, section) in menu.sections.enumerated() {
            if index > 0 { rows.append(.separator) }
            if let header = section.header { rows.append(.header(header, hint: section.headerHint)) }
            rows += section.items.map { .item(item($0)) }
        }
        return MenuContent(rows: rows, minWidth: minWidth)
    }

    private static func modelContent(of model: ComposerPresentation) -> MenuContent {
        var rows: [MenuContent.Row] = []
        if let header = model.modelPanelHeader { rows.append(.header(header)) }
        for section in model.modelSections {
            rows.append(
                .account(
                    mark: ComposerGlyph.image(section.glyph, size: 14) ?? NSImage(), name: section.name,
                    detail: section.detail, note: section.note))
            rows += section.items.map { .item(item($0)) }
        }
        let fast = model.fastMode
        let fastMode = MenuContent.Item(
            id: Choice.fastMode, title: String(localized: "Fast Mode", bundle: .module), subtitle: fast.subtitle,
            glyph: ComposerGlyph.menuImage(.fast), isEnabled: fast.isEnabled, trailing: .toggle(isOn: fast.isOn),
            toolTip: fast.subtitle)
        return MenuContent(rows: rows, footer: [fastMode], minWidth: 300)
    }

    private static func item(_ item: ComposerPresentation.Item) -> MenuContent.Item {
        MenuContent.Item(
            id: Choice.item(item.id), title: item.title, subtitle: item.subtitle,
            glyph: item.glyph.flatMap(ComposerGlyph.menuImage), isChecked: item.isChecked, isEnabled: item.isEnabled,
            isDanger: item.isDanger,
            trailing: item.restarts ? .glyph(ComposerGlyph.image(.restart, size: 14) ?? NSImage()) : .none)
    }
}
