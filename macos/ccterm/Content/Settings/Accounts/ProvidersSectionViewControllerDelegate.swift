import Foundation

/// What the person asked of the API Providers section.
@MainActor
protocol ProvidersSectionViewControllerDelegate: AnyObject {
    func providersSectionDidRequestAdd(_ section: ProvidersSectionViewController)
    /// Import from Clipboard, under Add Provider….
    func providersSectionDidRequestImport(_ section: ProvidersSectionViewController)
    /// ⓘ, a double click or Details….
    func providersSection(_ section: ProvidersSectionViewController, didOpen account: Account)
    func providersSection(_ section: ProvidersSectionViewController, didRequestDuplicate account: Account)
    /// Delete… from the row's menu — to confirm.
    func providersSection(_ section: ProvidersSectionViewController, didRequestDelete account: Account)
}
