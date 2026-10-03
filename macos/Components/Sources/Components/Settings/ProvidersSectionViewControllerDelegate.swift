import Foundation

/// What the person asked of the API Providers section.
@MainActor
public protocol ProvidersSectionViewControllerDelegate: AnyObject {
    func providersSectionDidRequestAdd(_ section: ProvidersSectionViewController)
    /// Import from Clipboard, under Add Provider….
    func providersSectionDidRequestImport(_ section: ProvidersSectionViewController)
    /// Whether the clipboard holds something to import — asked each time the
    /// menu opens.
    func providersSectionCanImport(_ section: ProvidersSectionViewController) -> Bool
    /// ⓘ, a double click or Details….
    func providersSection(_ section: ProvidersSectionViewController, didOpen id: UUID)
    func providersSection(_ section: ProvidersSectionViewController, didRequestDuplicate id: UUID)
    /// Delete… from the row's menu — to confirm.
    func providersSection(_ section: ProvidersSectionViewController, didRequestDelete id: UUID)
}
