import CoreData

final class CoreDataStack {

    static let shared = CoreDataStack()

    let persistentContainer: NSPersistentContainer

    var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    private init() {
        persistentContainer = NSPersistentContainer(name: "ccterm")
        persistentContainer.loadPersistentStores { _, error in
            if let error {
                appLog(.error, "CoreDataStack", "Failed to load store: \(error)")
            }
        }
        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
    }

    /// Test-only: in-memory store, no disk writes.
    internal init(inMemory: Bool) {
        persistentContainer = NSPersistentContainer(name: "ccterm")
        if inMemory {
            let desc = NSPersistentStoreDescription()
            desc.type = NSInMemoryStoreType
            persistentContainer.persistentStoreDescriptions = [desc]
        }
        persistentContainer.loadPersistentStores { _, error in
            if let error {
                appLog(.error, "CoreDataStack", "Failed to load store: \(error)")
            }
        }
        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
    }

    /// Workaround: macOS 26 SDK's `swift_task_deinitOnExecutorImpl` hits a libmalloc
    /// pointer-freed-but-not-allocated crash in the isolated deinit chain. Explicit
    /// nonisolated deinit skips the executor-hop path. See SessionHandle2.swift for details.
    nonisolated deinit {}

    func saveContext() {
        let context = viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            appLog(.error, "CoreDataStack", "Save failed: \(error)")
        }
    }
}
