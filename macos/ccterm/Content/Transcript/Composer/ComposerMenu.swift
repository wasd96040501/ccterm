import AppKit
import Components

/// The composer's three pop-ups as the one menu (`MenuContent`, design 08
/// *Model*, *Effort*, *Permission mode*): Effort and Mode a section head with
/// its items, Mode's Bypass past a hairline; Model a panel, a section per
/// account under its sticky head, *N More Models* expanding in place, and Fast
/// Mode's switch under the scroll.
@MainActor
enum ComposerMenu {
    /// What a chosen item stands for.
    enum Choice: Hashable {
        case change(SessionSettings.Change)
        /// *N More Models* of the account section with this id.
        case more(UUID)
        /// The Fast Mode switch.
        case fastMode
    }

    /// Effort's or Mode's menu.
    static func content(of menu: ComposerModel.Menu) -> MenuContent {
        var rows: [MenuContent.Row] = []
        for (index, section) in menu.sections.enumerated() {
            if index > 0 { rows.append(.separator) }
            if let header = section.header { rows.append(.header(.title(header, hint: section.headerHint))) }
            rows += section.items.map { .item(item($0)) }
        }
        return MenuContent(rows: rows)
    }

    /// The model panel, with the sections in `expanded` unfolded.
    static func modelContent(of model: ComposerModel, expanded: Set<UUID>) -> MenuContent {
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
                            title: String(localized: "\(section.foldedItems.count) More Models"), isMore: true)))
            }
        }
        let fast = model.fastMode
        let footer = MenuContent.Row.item(
            MenuContent.Item(
                id: Choice.fastMode, title: String(localized: "Fast Mode"), subtitle: fast.subtitle,
                glyph: ComposerGlyph.menuImage(.fast), isEnabled: fast.isEnabled,
                trailing: .toggle(isOn: fast.isOn), toolTip: fast.subtitle))
        return MenuContent(rows: rows, footer: [footer], isPanel: true)
    }

    private static func item(_ item: ComposerModel.Item) -> MenuContent.Item {
        MenuContent.Item(
            id: Choice.change(item.change), title: item.title, subtitle: item.subtitle,
            glyph: item.glyph.flatMap(ComposerGlyph.menuImage), isChecked: item.isChecked, isEnabled: item.isEnabled,
            isDanger: item.isDanger,
            trailing: item.restarts ? .glyph(ComposerGlyph.image(.restart, size: 14) ?? NSImage()) : .none)
    }
}
