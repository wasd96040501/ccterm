import Foundation
import Combine
import CoreData

// MARK: - TodoService

final class TodoService: ObservableObject {

    // MARK: - Properties

    static let shared = TodoService()

    private let coreDataStack: CoreDataStack
    @Published private(set) var cachedTodos: [TodoItem] = []

    // MARK: - Lifecycle

    private init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
        loadAll()
    }

    // MARK: - CRUD

    @discardableResult
    func createTodo(title: String, type: TodoItemType = .normal, metadata: TodoMetadata? = nil) -> TodoItem {
        let item = TodoItem(
            title: title,
            status: .pending,
            type: type,
            metadata: metadata
        )
        cachedTodos.append(item)
        saveToCoreData(item)

        return item
    }

    func deleteTodo(id: UUID) {
        guard let index = cachedTodos.firstIndex(where: { $0.id == id }),
              !cachedTodos[index].isDeleted else { return }
        cachedTodos[index].previousStatus = cachedTodos[index].status
        cachedTodos[index].isDeleted = true
        cachedTodos[index].deletedAt = Date()
        cachedTodos[index].updatedAt = Date()
        saveToCoreData(cachedTodos[index])

    }

    func restoreTodo(id: UUID) {
        guard let index = cachedTodos.firstIndex(where: { $0.id == id }) else { return }
        cachedTodos[index].isDeleted = false
        cachedTodos[index].deletedAt = nil
        if let previous = cachedTodos[index].previousStatus {
            cachedTodos[index].status = previous
        }
        cachedTodos[index].previousStatus = nil
        cachedTodos[index].updatedAt = Date()
        saveToCoreData(cachedTodos[index])

    }

    func permanentlyDelete(id: UUID) {
        cachedTodos.removeAll { $0.id == id }
        deleteCDTodoItem(id: id)

    }

    // MARK: - Status Transitions

    func updateSessionId(_ sessionId: String, for todoId: UUID) {
        guard let index = cachedTodos.firstIndex(where: { $0.id == todoId }) else { return }
        cachedTodos[index].sessionId = sessionId
        cachedTodos[index].updatedAt = Date()
        saveToCoreData(cachedTodos[index])

    }

    func updateWorktreeBranch(_ branch: String, for todoId: UUID) {
        guard let index = cachedTodos.firstIndex(where: { $0.id == todoId }) else { return }
        cachedTodos[index].worktreeBranch = branch
        cachedTodos[index].updatedAt = Date()
        saveToCoreData(cachedTodos[index])

    }

    func markNeedsConfirmation(id: UUID) {
        updateStatus(id: id, to: .needsConfirmation)
    }

    func markInProgress(id: UUID) {
        updateStatus(id: id, to: .inProgress)
    }

    func markCompleted(id: UUID) {
        updateStatus(id: id, to: .completed)
    }

    func markMerged(id: UUID) {
        updateStatus(id: id, to: .merged)
    }

    func updateMergedItemIds(_ ids: [String], for todoId: UUID) {
        guard let index = cachedTodos.firstIndex(where: { $0.id == todoId }) else { return }
        cachedTodos[index].mergedItemIds = ids
        cachedTodos[index].updatedAt = Date()
        saveToCoreData(cachedTodos[index])

    }

    // MARK: - Queries

    func allTodos() -> [TodoItem] {
        cachedTodos.filter { !$0.isDeleted }
    }

    func todos(status: TodoStatus) -> [TodoItem] {
        cachedTodos.filter { !$0.isDeleted && $0.status == status }
    }

    func deletedTodos() -> [TodoItem] {
        cachedTodos.filter { $0.isDeleted }
    }

    func todo(forId id: UUID) -> TodoItem? {
        cachedTodos.first { $0.id == id }
    }

    func todo(forSessionId sessionId: String) -> TodoItem? {
        cachedTodos.first { $0.sessionId == sessionId }
    }

    // MARK: - Private Methods

    private static let validTransitions: [TodoStatus: Set<TodoStatus>] = [
        .pending: [.needsConfirmation],
        .needsConfirmation: [.inProgress],
        .inProgress: [.completed],
        .completed: [.merged],
    ]

    private func updateStatus(id: UUID, to status: TodoStatus) {
        guard let index = cachedTodos.firstIndex(where: { $0.id == id }) else { return }
        let current = cachedTodos[index].status
        guard Self.validTransitions[current]?.contains(status) == true else {
            NSLog("[TodoService] Invalid transition: %@ -> %@", current.rawValue, status.rawValue)
            return
        }
        cachedTodos[index].status = status
        cachedTodos[index].updatedAt = Date()
        saveToCoreData(cachedTodos[index])

    }

    private func loadAll() {
        let context = coreDataStack.viewContext
        let request = NSFetchRequest<CDTodoItem>(entityName: "CDTodoItem")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

        do {
            let results = try context.fetch(request)
            cachedTodos = results.compactMap { Self.todoItem(from: $0) }
        } catch {
            NSLog("[TodoService] Fetch failed: \(error)")
        }
    }

    private func saveToCoreData(_ item: TodoItem) {
        let context = coreDataStack.viewContext
        let request = NSFetchRequest<CDTodoItem>(entityName: "CDTodoItem")
        request.predicate = NSPredicate(format: "uuid == %@", item.id as CVarArg)
        request.fetchLimit = 1

        let existing = (try? context.fetch(request))?.first
        let entity = existing ?? CDTodoItem(context: context)

        entity.uuid = item.id
        entity.title = item.title
        entity.status = item.status.rawValue
        entity.type = item.type.rawValue
        entity.metadataJSON = Self.encodeMetadata(item.metadata)
        entity.sessionId = item.sessionId
        entity.worktreeBranch = item.worktreeBranch
        entity.mergedItemIdsJSON = Self.encodeMergedItemIds(item.mergedItemIds)
        entity.isSoftDeleted = item.isDeleted
        entity.deletedAt = item.deletedAt
        entity.previousStatus = item.previousStatus?.rawValue
        entity.createdAt = item.createdAt
        entity.updatedAt = item.updatedAt

        coreDataStack.saveContext()
    }

    private func deleteCDTodoItem(id: UUID) {
        let context = coreDataStack.viewContext
        let request = NSFetchRequest<CDTodoItem>(entityName: "CDTodoItem")
        request.predicate = NSPredicate(format: "uuid == %@", id as CVarArg)
        request.fetchLimit = 1

        guard let entity = (try? context.fetch(request))?.first else { return }
        context.delete(entity)
        coreDataStack.saveContext()
    }

    // MARK: - Mapping

    private static func todoItem(from entity: CDTodoItem) -> TodoItem? {
        guard let uuid = entity.uuid,
              let title = entity.title,
              let statusRaw = entity.status,
              let status = TodoStatus(rawValue: statusRaw),
              let typeRaw = entity.type,
              let type = TodoItemType(rawValue: typeRaw),
              let createdAt = entity.createdAt,
              let updatedAt = entity.updatedAt else {
            return nil
        }

        return TodoItem(
            id: uuid,
            title: title,
            status: status,
            type: type,
            metadata: decodeMetadata(entity.metadataJSON),
            sessionId: entity.sessionId,
            worktreeBranch: entity.worktreeBranch,
            mergedItemIds: decodeMergedItemIds(entity.mergedItemIdsJSON),
            isDeleted: entity.isSoftDeleted,
            deletedAt: entity.deletedAt,
            previousStatus: entity.previousStatus.flatMap { TodoStatus(rawValue: $0) },
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - JSON Encoding

    private static func encodeMetadata(_ metadata: TodoMetadata?) -> String? {
        guard let metadata, let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeMetadata(_ json: String?) -> TodoMetadata? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TodoMetadata.self, from: data)
    }

    private static func encodeMergedItemIds(_ ids: [String]?) -> String? {
        guard let ids, let data = try? JSONEncoder().encode(ids) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeMergedItemIds(_ json: String?) -> [String]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}
