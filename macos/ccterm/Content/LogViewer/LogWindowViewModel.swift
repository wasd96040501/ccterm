import Foundation

@Observable
@MainActor
final class LogWindowViewModel {
    var searchText: String = ""
    var selectedLevel: LogLevel? = nil
    var selectedCategory: String? = nil

    var filteredEntries: [LogEntry] {
        var result = AppLogger.shared.entries

        if let level = selectedLevel {
            result = result.filter { $0.level >= level }
        }

        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.message.localizedCaseInsensitiveContains(searchText)
                    || $0.category.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    var availableCategories: [String] {
        AppLogger.shared.categories.sorted()
    }

    func clear() {
        AppLogger.shared.clear()
    }
}
